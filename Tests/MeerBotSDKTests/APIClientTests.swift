// Сетевой слой: форма запросов (сверено с роутами `/api/v1/mobile/*` в agentbot-platform),
// обновление токена, поведение при обрыве соединения.

import XCTest
@testable import MeerBotSDK

final class APIClientTests: XCTestCase {

    private let visitorUuid = "11111111-2222-4333-8444-555555555555"
    private let installationId = "99999999-8888-4777-8666-555555555555"

    private let registerPath = "/api/v1/mobile/register"
    private let streamPath = "/api/v1/mobile/chat/stream"
    private let messagesPath = "/api/v1/mobile/messages"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeClient() -> APIClient {
        APIClient(
            config: MeerBotConfiguration(
                apiKey: "pk_live_test",
                baseURL: URL(string: "https://meerbot.test")!,
                sdkVersion: "0.2.0"
            ),
            visitorUuid: visitorUuid,
            installationId: installationId,
            sessionConfiguration: .stubbed()
        )
    }

    private func stubRegister(
        jwt: String = "jwt-1",
        expiresIn: Int = 900,
        identityStatus: String = "not_provided"
    ) {
        StubURLProtocol.enqueue(
            path: registerPath,
            .json([
                "deviceId": "42",
                "jwt": jwt,
                "expiresIn": expiresIn,
                "attestationRequired": false,
                "identity": ["status": identityStatus],
            ])
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ChatStreamEvent, Error>
    ) async -> (events: [ChatStreamEvent], error: Error?) {
        var events: [ChatStreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    // MARK: Регистрация (она же сессия)

    func testРегистрацияИдётОднимКлючомВМобильныйРоутБезOrigin() async throws {
        stubRegister()
        let session = try await makeClient().openSession()

        XCTAssertEqual(session.jwt, "jwt-1")
        XCTAssertEqual(session.deviceId, "42")

        let request = try XCTUnwrap(StubURLProtocol.requests(path: registerPath).first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body?["key"] as? String, "pk_live_test")
        XCTAssertEqual(request.body?["platform"] as? String, "ios")
        XCTAssertEqual(request.body?["visitorUuid"] as? String, visitorUuid)
        XCTAssertEqual(request.headers["X-SDK-Version"], "0.2.0")
        // Origin — часть виджетного контракта: мобильные роуты его не проверяют, а
        // требование вписать домен приложения в кабинет было платой за чужой handshake.
        XCTAssertNil(request.headers["Origin"])
    }

    /// `deviceToken` — ключ уникальности устройства, а от него зависит ТРЕД диалога.
    /// APNs-токен туда слать нельзя: его ротация завела бы пользователю новый пустой диалог.
    func testDeviceTokenЭтоСтабильныйИдентификаторУстановкиАНеAPNs() async throws {
        stubRegister()
        stubRegister(jwt: "jwt-2", expiresIn: 30)
        let client = makeClient()

        _ = try await client.openSession()
        _ = try await client.openSession()

        let tokens = StubURLProtocol.requests(path: registerPath)
            .compactMap { $0.body?["deviceToken"] as? String }
        XCTAssertEqual(tokens, [installationId, installationId], "значение стабильно между сессиями")
    }

    func testОшибкаКлючаПриходитМашиннымКодом() async {
        StubURLProtocol.enqueue(
            path: registerPath,
            .json([
                "error": ["type": "authentication_error", "code": "key_invalid", "message": "Invalid key"],
            ], status: 401)
        )
        do {
            _ = try await makeClient().openSession()
            XCTFail("ожидалась ошибка")
        } catch let error as MeerBotError {
            XCTAssertEqual(error.code, "key_invalid")
            XCTAssertTrue(error.userMessage.contains("ключ"))
        } catch {
            XCTFail("неожиданный тип ошибки: \(error)")
        }
    }

    /// Коды мобильных роутов разошлись с виджетными. Незнакомый код давал бы бесполезное
    /// «Сервер недоступен» на причине, которую пользователь может устранить сам.
    func testОтказыКаналаОбъясняютсяПользователюПоСвоимКодам() {
        let cases: [(String, Int, String)] = [
            ("identity_required", 403, "требует входа"),
            ("mobile_app_inactive", 403, "отключён"),
            ("assistant_disabled", 403, "Ассистент"),
            ("daily_budget_exceeded", 402, "лимит расходов"),
            ("conversation_cap_reached", 429, "месячный лимит"),
            ("rate_limited", 429, "Слишком много"),
        ]
        for (code, status, expected) in cases {
            let error = MeerBotError.http(status: status, code: code, message: "")
            XCTAssertTrue(
                error.userMessage.contains(expected),
                "код \(code): «\(error.userMessage)» не объясняет причину"
            )
        }
    }

    // MARK: Verified identity

    func testIdentityТокенУходитВРегистрациюИСтатусЧитаетсяИзОтвета() async throws {
        stubRegister(identityStatus: "verified")
        let client = makeClient()
        await client.setIdentityToken("signed.jwt.here")

        let session = try await client.openSession()

        XCTAssertEqual(session.identityStatus, .verified)
        let status = await client.identityStatus
        XCTAssertEqual(status, .verified)
        let request = try XCTUnwrap(StubURLProtocol.requests(path: registerPath).first)
        XCTAssertEqual(request.body?["identityToken"] as? String, "signed.jwt.here")
    }

    /// Провал проверки SOFT: сессия живёт, но пользователь анонимен. Без статуса в ответе
    /// интегратор внедрил бы идентификацию и не узнал, что она молча не работает.
    func testОтклонённыйIdentityНеРоняетСессиюНоВиденВСтатусе() async throws {
        stubRegister(identityStatus: "rejected")
        let client = makeClient()
        await client.setIdentityToken("bad.token")

        let session = try await client.openSession()

        XCTAssertEqual(session.jwt, "jwt-1", "сессия открыта")
        XCTAssertEqual(session.identityStatus, .rejected)
    }

    func testБезIdentityТокенаПолеВЗапросНеУходит() async throws {
        stubRegister()
        _ = try await makeClient().openSession()

        let request = try XCTUnwrap(StubURLProtocol.requests(path: registerPath).first)
        XCTAssertNil(request.body?["identityToken"])
    }

    // MARK: Токен

    func testДействующийТокенПереиспользуетсяБезПовторнойРегистрации() async throws {
        stubRegister(expiresIn: 900)
        let client = makeClient()

        _ = try await client.validToken()
        _ = try await client.validToken()

        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 1)
    }

    func testПротухающийТокенОбновляетсяНовойРегистрацией() async throws {
        // expiresIn=30 — меньше минутного запаса, значит токен считается непригодным.
        stubRegister(jwt: "jwt-short", expiresIn: 30)
        stubRegister(jwt: "jwt-short-2", expiresIn: 30)
        let client = makeClient()

        _ = try await client.validToken()
        _ = try await client.validToken()

        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 2)
    }

    func testПараллельныеЗапросыТокенаДелятОднуРегистрацию() async throws {
        stubRegister()
        let client = makeClient()

        async let first = client.validToken()
        async let second = client.validToken()
        _ = try await (first, second)

        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 1)
    }

    func testИстёкшийТокенВПотокеОбновляетсяИЗапросПовторяетсяОдинРаз() async throws {
        stubRegister(jwt: "jwt-old", expiresIn: 900)
        stubRegister(jwt: "jwt-new", expiresIn: 900)
        StubURLProtocol.enqueue(
            path: streamPath,
            .json([
                "error": ["type": "authentication_error", "code": "jwt_expired", "message": "JWT expired"],
            ], status: 401),
            .sse("event: meta\ndata: {\"conversationId\":5,\"mode\":\"ai\"}\n\ndata: [DONE]\n\n")
        )

        let client = makeClient()
        let (events, error) = await collect(client.sendMessage("привет"))

        XCTAssertNil(error)
        XCTAssertEqual(events, [.meta(conversationId: 5, mode: .ai), .done])

        let streamRequests = StubURLProtocol.requests(path: streamPath)
        XCTAssertEqual(streamRequests.count, 2, "ровно одна повторная попытка")
        XCTAssertEqual(streamRequests[0].headers["Authorization"], "Bearer jwt-old")
        XCTAssertEqual(streamRequests[1].headers["Authorization"], "Bearer jwt-new")
    }

    func testПовторноеИстечениеТокенаНеЗацикливается() async {
        stubRegister(jwt: "jwt-any", expiresIn: 900)
        StubURLProtocol.enqueue(
            path: streamPath,
            .json([
                "error": ["type": "authentication_error", "code": "jwt_expired", "message": "JWT expired"],
            ], status: 401)
        )

        let client = makeClient()
        let (_, error) = await collect(client.sendMessage("привет"))

        XCTAssertEqual((error as? MeerBotError)?.code, "jwt_expired")
        XCTAssertEqual(StubURLProtocol.requests(path: streamPath).count, 2)
    }

    /// `channel_mismatch` — токен НЕ протух, он от другого канала (403). Перевыпуск его не
    /// исправит, и повтор здесь был бы бессмысленной второй платной попыткой.
    func testЧужойКаналНеПовторяется() async {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .json([
                "error": ["type": "authentication_error", "code": "channel_mismatch", "message": "wrong channel"],
            ], status: 403)
        )

        let client = makeClient()
        let (_, error) = await collect(client.sendMessage("привет"))

        XCTAssertEqual((error as? MeerBotError)?.code, "channel_mismatch")
        XCTAssertEqual(StubURLProtocol.requests(path: streamPath).count, 1, "повтора быть не должно")
    }

    // MARK: Поток чата

    func testФормаЗапросаЧатаСовпадаетСКонтрактомБэкенда() async throws {
        stubRegister()
        StubURLProtocol.enqueue(path: streamPath, .sse("data: [DONE]\n\n"))

        let client = makeClient()
        await client.setConversationId(77)
        _ = await collect(client.sendMessage("вопрос"))

        let request = try XCTUnwrap(StubURLProtocol.requests(path: streamPath).first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Accept"], "text/event-stream")
        XCTAssertEqual(request.body?["message"] as? String, "вопрос")
        // Диалог выбирает СЕРВЕР по паре (приложение, устройство). Слать id значило бы
        // делать вид, что клиент может выбрать чужой тред.
        XCTAssertNil(request.body?["conversationId"])
    }

    func testСобираетОтветИзМножестваЧанковИЗапоминаетДиалог() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .sse(
                """
                event: meta
                data: {"conversationId":123,"mode":"ai"}

                data: {"choices":[{"delta":{"content":"Здрав"}}]}

                data: {"choices":[{"delta":{"content":"ствуйте!"}}]}

                event: heartbeat
                data: {}

                data: [DONE]


                """,
                chunkSize: 7 // рвём поток в произвольных местах, включая середину слов
            )
        )

        let client = makeClient()
        let (events, error) = await collect(client.sendMessage("привет"))

        XCTAssertNil(error)
        let text = events.compactMap { if case let .contentDelta(t) = $0 { return t } else { return nil } }
        XCTAssertEqual(text.joined(), "Здравствуйте!")
        XCTAssertTrue(events.contains(.done))
        let conversationId = await client.conversationId
        XCTAssertEqual(conversationId, 123, "id диалога приходит из meta — для подавления своего пуша")
    }

    /// Диалог у менеджера: модель не зовётся, сервер отдаёт `forwarded_to_manager` и
    /// закрывает поток. Для клиента это НЕ ошибка — сообщение доставлено человеку.
    func testРежимМенеджераПриходитСобытиемАНеОшибкой() async {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .sse(
                "event: meta\ndata: {\"conversationId\":8,\"mode\":\"human\"}\n\n"
                    + "event: forwarded_to_manager\ndata: {\"mode\":\"human\"}\n\n"
            )
        )

        let (events, error) = await collect(makeClient().sendMessage("хочу человека"))

        XCTAssertNil(error)
        XCTAssertEqual(
            events,
            [.meta(conversationId: 8, mode: .human), .forwardedToManager(mode: .human)]
        )
    }

    func testОбрывПосредиОтветаОтдаётСетевуюОшибкуИСохраняетПолученное() async {
        stubRegister()
        var dropped = StubResponse.sse(
            "event: meta\ndata: {\"conversationId\":9,\"mode\":\"ai\"}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Начал отвеч\"}}]}\n\n"
        )
        dropped.failure = URLError(.networkConnectionLost)
        dropped.chunkDelay = 0.05
        StubURLProtocol.enqueue(path: streamPath, dropped)

        let client = makeClient()
        let (events, error) = await collect(client.sendMessage("привет"))

        XCTAssertEqual(events, [.meta(conversationId: 9, mode: .ai), .contentDelta("Начал отвеч")])
        XCTAssertEqual((error as? MeerBotError)?.code, "network_\(URLError.Code.networkConnectionLost.rawValue)")
        XCTAssertEqual((error as? MeerBotError)?.userMessage, "Нет связи с сервером. Проверьте интернет и повторите.")
    }

    func testНедоступностьСетиНаРегистрацииНеПревращаетсяВМолчание() async {
        var failure = StubResponse.json([:])
        failure.chunks = []
        failure.failure = URLError(.notConnectedToInternet)
        StubURLProtocol.enqueue(path: registerPath, failure)

        let (_, error) = await collect(makeClient().sendMessage("привет"))
        XCTAssertEqual((error as? MeerBotError)?.code, "network_\(URLError.Code.notConnectedToInternet.rawValue)")
    }

    func testОшибкаВнутриПотокаДоходитОтдельнымСобытием() async {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .sse("event: error\ndata: {\"code\":\"ai_unavailable\",\"message\":\"AI down\"}\n\n")
        )

        let (events, error) = await collect(makeClient().sendMessage("привет"))
        XCTAssertNil(error, "серверная ошибка приходит событием, а не обрывом стрима")
        XCTAssertEqual(events, [.serverError(code: "ai_unavailable", message: "AI down")])
    }

    // MARK: История

    func testДогонИсторииИдётБезIdДиалога() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [
                    ["id": 10, "role": "user", "content": "привет", "createdAt": "2026-08-15T10:00:00.000Z"],
                    ["id": 11, "role": "assistant", "content": "Здравствуйте!", "createdAt": "2026-08-15T10:00:02.000Z"],
                ],
                "hasMore": false,
                "mode": "human",
            ])
        )

        let client = makeClient()
        let page = try await client.history(since: 5, limit: 20)

        XCTAssertEqual(page.messages.map(\.content), ["привет", "Здравствуйте!"])
        XCTAssertEqual(page.mode, .human, "режим треда приходит тем же ответом")
        XCTAssertFalse(page.hasMore)

        let request = try XCTUnwrap(StubURLProtocol.requests(path: messagesPath).first)
        let query = request.url.query ?? ""
        XCTAssertTrue(query.contains("since=5"))
        XCTAssertTrue(query.contains("limit=20"))
        // Тред резолвится по устройству из токена: id в параметре означал бы, что клиент
        // выбирает, чью историю читать.
        XCTAssertFalse(query.contains("conversationId"))
        XCTAssertNotNil(request.headers["Authorization"])
    }

    /// Ответ менеджера в истории обязан оставаться ответом менеджера.
    ///
    /// В потоке автор приходит кадром `operator_message`, но после перезапуска приложения
    /// лента перечитывается из `/messages` — и до 2026-08-23 подпись человека там терялась:
    /// клиент видел ответ живого оператора как ответ бота ровно в том сценарии, ради
    /// которого канал и делался («менеджер ответил → пуш → пользователь вернулся»).
    func testАвторСообщенияВИсторииРазличаетМенеджераИБота() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [
                    ["id": 20, "role": "assistant", "content": "Я бот", "authorKind": "ai"],
                    [
                        "id": 21,
                        "role": "assistant",
                        "content": "Я живой",
                        "authorKind": "manager",
                        "authorName": "Роман",
                    ],
                ],
                "hasMore": false,
                "mode": "human",
            ])
        )

        let page = try await makeClient().history()

        XCTAssertEqual(page.messages.map(\.authorKind), ["ai", "manager"])
        XCTAssertEqual(page.messages.last?.authorName, "Роман")
    }

    /// Старая сборка платформы поля не отдаёт — автор считается ботом, как и раньше.
    /// Фолбэк важен: SDK обновляется у клиента раньше, чем катится наш деплой.
    func testИсторияБезПоляАвтораНеЛомается() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [["id": 30, "role": "assistant", "content": "Ответ"]],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let page = try await makeClient().history()

        XCTAssertNil(page.messages.first?.authorKind)
    }

    /// Диалога ещё нет (пользователь не писал) — сервер отвечает пустой лентой и 200.
    /// Для клиента это штатный старт, а не ошибка.
    func testПустаяИсторияДоПервогоСообщенияНеОшибка() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json(["messages": [], "hasMore": false, "mode": "ai"])
        )

        let page = try await makeClient().history()

        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertEqual(page.mode, .ai)
    }
}
