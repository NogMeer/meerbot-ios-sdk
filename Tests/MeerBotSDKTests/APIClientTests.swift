// Сетевой слой: форма запросов (сверено с роутами agentbot-platform), обновление токена,
// поведение при обрыве соединения.

import XCTest
@testable import MeerBotSDK

final class APIClientTests: XCTestCase {

    private let visitorUuid = "11111111-2222-4333-8444-555555555555"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeClient(pushApiKey: String? = nil) -> APIClient {
        APIClient(
            config: MeerBotConfiguration(
                apiKey: "pk_live_test",
                pushApiKey: pushApiKey,
                baseURL: URL(string: "https://meerbot.test")!,
                origin: "https://ru.tumanvpn.app",
                sdkVersion: "0.1.0"
            ),
            visitorUuid: visitorUuid,
            sessionConfiguration: .stubbed()
        )
    }

    private func stubSession(jwt: String = "jwt-1", expiresIn: Int = 900, conversationId: Any = NSNull()) {
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/session",
            .json([
                "sessionId": "s1",
                "jwt": jwt,
                "expiresIn": expiresIn,
                "conversationId": conversationId,
                "mode": "ai",
                "widget": ["id": 1, "title": "Поддержка", "greeting": "Привет!"],
            ], status: 201)
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

    // MARK: Handshake

    func testHandshakeШлётКлючВизитораИOrigin() async throws {
        stubSession()
        let session = try await makeClient().openSession()

        XCTAssertEqual(session.jwt, "jwt-1")
        XCTAssertEqual(session.title, "Поддержка")
        XCTAssertEqual(session.greeting, "Привет!")

        let request = try XCTUnwrap(StubURLProtocol.requests(path: "/api/v1/widget/session").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Origin"], "https://ru.tumanvpn.app")
        XCTAssertEqual(request.headers["X-SDK-Version"], "0.1.0")
        XCTAssertEqual(request.body?["key"] as? String, "pk_live_test")
        XCTAssertEqual(request.body?["visitorUuid"] as? String, visitorUuid)
    }

    func testОшибкаКлючаПриходитМашиннымКодом() async {
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/session",
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

    // MARK: Токен

    func testДействующийТокенПереиспользуетсяБезПовторногоHandshake() async throws {
        stubSession(expiresIn: 900)
        let client = makeClient()

        _ = try await client.validToken()
        _ = try await client.validToken()

        XCTAssertEqual(StubURLProtocol.requests(path: "/api/v1/widget/session").count, 1)
    }

    func testПротухающийТокенОбновляетсяНовымHandshake() async throws {
        // expiresIn=30 — меньше минутного запаса, значит токен считается непригодным.
        stubSession(jwt: "jwt-short", expiresIn: 30)
        let client = makeClient()

        _ = try await client.validToken()
        _ = try await client.validToken()

        XCTAssertEqual(StubURLProtocol.requests(path: "/api/v1/widget/session").count, 2)
    }

    func testПараллельныеЗапросыТокенаДелятОдинHandshake() async throws {
        stubSession()
        let client = makeClient()

        async let first = client.validToken()
        async let second = client.validToken()
        _ = try await (first, second)

        XCTAssertEqual(StubURLProtocol.requests(path: "/api/v1/widget/session").count, 1)
    }

    func testИстёкшийТокенВПотокеОбновляетсяИЗапросПовторяетсяОдинРаз() async throws {
        stubSession(jwt: "jwt-old", expiresIn: 900)
        stubSession(jwt: "jwt-new", expiresIn: 900)
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/chat/stream",
            .json([
                "error": ["type": "authentication_error", "code": "jwt_expired", "message": "JWT expired"],
            ], status: 401),
            .sse("event: meta\ndata: {\"conversationId\":5,\"mode\":\"ai\"}\n\ndata: [DONE]\n\n")
        )

        let client = makeClient()
        let (events, error) = await collect(client.sendMessage("привет"))

        XCTAssertNil(error)
        XCTAssertEqual(events, [.meta(conversationId: 5, mode: .ai), .done])

        let streamRequests = StubURLProtocol.requests(path: "/api/v1/widget/chat/stream")
        XCTAssertEqual(streamRequests.count, 2, "ровно одна повторная попытка")
        XCTAssertEqual(streamRequests[0].headers["Authorization"], "Bearer jwt-old")
        XCTAssertEqual(streamRequests[1].headers["Authorization"], "Bearer jwt-new")
    }

    func testПовторноеИстечениеТокенаНеЗацикливается() async {
        stubSession(jwt: "jwt-any", expiresIn: 900)
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/chat/stream",
            .json([
                "error": ["type": "authentication_error", "code": "jwt_expired", "message": "JWT expired"],
            ], status: 401)
        )

        let client = makeClient()
        let (_, error) = await collect(client.sendMessage("привет"))

        XCTAssertEqual((error as? MeerBotError)?.code, "jwt_expired")
        XCTAssertEqual(StubURLProtocol.requests(path: "/api/v1/widget/chat/stream").count, 2)
    }

    // MARK: Поток чата

    func testФормаЗапросаЧатаСовпадаетСКонтрактомБэкенда() async throws {
        stubSession()
        StubURLProtocol.enqueue(path: "/api/v1/widget/chat/stream", .sse("data: [DONE]\n\n"))

        let client = makeClient()
        await client.setConversationId(77)
        _ = await collect(client.sendMessage("вопрос"))

        let request = try XCTUnwrap(StubURLProtocol.requests(path: "/api/v1/widget/chat/stream").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Accept"], "text/event-stream")
        XCTAssertEqual(request.headers["Origin"], "https://ru.tumanvpn.app")
        // Бэкенд ждёт именно `message` (не `content`) и числовой conversationId.
        XCTAssertEqual(request.body?["message"] as? String, "вопрос")
        XCTAssertEqual(request.body?["conversationId"] as? Int, 77)
    }

    func testСобираетОтветИзМножестваЧанковИЗапоминаетДиалог() async throws {
        stubSession()
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/chat/stream",
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
        XCTAssertEqual(conversationId, 123, "id диалога запоминается из meta для следующего запроса")
    }

    func testОбрывПосредиОтветаОтдаётСетевуюОшибкуИСохраняетПолученное() async {
        stubSession()
        var dropped = StubResponse.sse(
            "event: meta\ndata: {\"conversationId\":9,\"mode\":\"ai\"}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Начал отвеч\"}}]}\n\n"
        )
        dropped.failure = URLError(.networkConnectionLost)
        dropped.chunkDelay = 0.05
        StubURLProtocol.enqueue(path: "/api/v1/widget/chat/stream", dropped)

        let client = makeClient()
        let (events, error) = await collect(client.sendMessage("привет"))

        XCTAssertEqual(events, [.meta(conversationId: 9, mode: .ai), .contentDelta("Начал отвеч")])
        XCTAssertEqual((error as? MeerBotError)?.code, "network_\(URLError.Code.networkConnectionLost.rawValue)")
        XCTAssertEqual((error as? MeerBotError)?.userMessage, "Нет связи с сервером. Проверьте интернет и повторите.")
    }

    func testНедоступностьСетиНаHandshakeНеПревращаетсяВМолчание() async {
        var failure = StubResponse.json([:])
        failure.chunks = []
        failure.failure = URLError(.notConnectedToInternet)
        StubURLProtocol.enqueue(path: "/api/v1/widget/session", failure)

        let (_, error) = await collect(makeClient().sendMessage("привет"))
        XCTAssertEqual((error as? MeerBotError)?.code, "network_\(URLError.Code.notConnectedToInternet.rawValue)")
    }

    func testОшибкаВнутриПотокаДоходитОтдельнымСобытием() async {
        stubSession()
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/chat/stream",
            .sse("event: error\ndata: {\"code\":\"ai_unavailable\",\"message\":\"AI down\"}\n\n")
        )

        let (events, error) = await collect(makeClient().sendMessage("привет"))
        XCTAssertNil(error, "серверная ошибка приходит событием, а не обрывом стрима")
        XCTAssertEqual(events, [.serverError(code: "ai_unavailable", message: "AI down")])
    }

    // MARK: История и устройство

    func testДогонИсторииПослеОбрыва() async throws {
        stubSession()
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/messages",
            .json([
                "messages": [
                    ["id": 10, "role": "user", "content": "привет", "createdAt": "2026-08-11T10:00:00.000Z"],
                    ["id": 11, "role": "assistant", "content": "Здравствуйте!", "createdAt": "2026-08-11T10:00:02.000Z"],
                ],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let client = makeClient()
        await client.setConversationId(123)
        let messages = try await client.history()

        XCTAssertEqual(messages.map(\.content), ["привет", "Здравствуйте!"])
        let request = try XCTUnwrap(StubURLProtocol.requests(path: "/api/v1/widget/messages").first)
        XCTAssertTrue(request.url.query?.contains("conversationId=123") == true)
        XCTAssertNotNil(request.headers["Authorization"])
    }

    func testРегистрацияУстройстваИдётВMobileRegisterСКлючомПриложения() async throws {
        StubURLProtocol.enqueue(
            path: "/api/v1/mobile/register",
            .json(["deviceId": "42", "jwt": "mobile-jwt", "expiresIn": 900, "attestationRequired": true])
        )

        let client = makeClient(pushApiKey: "pk_live_mobile")
        let registration = try await client.registerDevice(apnsToken: "a1b2c3d4e5f6")

        XCTAssertEqual(registration.deviceId, "42")
        XCTAssertTrue(registration.attestationRequired)

        let request = try XCTUnwrap(StubURLProtocol.requests(path: "/api/v1/mobile/register").first)
        XCTAssertEqual(request.body?["key"] as? String, "pk_live_mobile")
        XCTAssertEqual(request.body?["platform"] as? String, "ios")
        XCTAssertEqual(request.body?["deviceToken"] as? String, "a1b2c3d4e5f6")
    }

    func testРегистрацияУстройстваБезКлючаПриложенияОтклоняется() async {
        do {
            _ = try await makeClient().registerDevice(apnsToken: "a1b2c3d4e5f6")
            XCTFail("ожидалась ошибка конфигурации")
        } catch let error as MeerBotError {
            XCTAssertEqual(error.code, "not_configured")
        } catch {
            XCTFail("неожиданный тип ошибки: \(error)")
        }
        XCTAssertTrue(StubURLProtocol.requests(path: "/api/v1/mobile/register").isEmpty)
    }

    /// JWT мобильной регистрации НЕ должен подменять токен чат-сессии: он подписан на другое
    /// пространство id (aud = ClientMobileApp.id) и chat/stream ответит 403.
    func testТокенИзMobileRegisterНеИспользуетсяДляЧата() async throws {
        StubURLProtocol.enqueue(
            path: "/api/v1/mobile/register",
            .json(["deviceId": "42", "jwt": "mobile-jwt", "expiresIn": 900])
        )
        stubSession(jwt: "widget-jwt")
        StubURLProtocol.enqueue(path: "/api/v1/widget/chat/stream", .sse("data: [DONE]\n\n"))

        let client = makeClient(pushApiKey: "pk_live_mobile")
        _ = try await client.registerDevice(apnsToken: "a1b2c3d4e5f6")
        _ = await collect(client.sendMessage("привет"))

        let request = try XCTUnwrap(StubURLProtocol.requests(path: "/api/v1/widget/chat/stream").first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer widget-jwt")
    }
}
