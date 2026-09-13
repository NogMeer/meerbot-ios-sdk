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

    /// Свой домен настроек на тест: флаг выхода живёт на диске, и `.standard` пронёс бы его
    /// из одного теста (и прогона) в другой.
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        suiteName = "MeerBotSDKTests.APIClient.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var flagStore: IdentityFlagStore { IdentityFlagStore(defaults: defaults) }

    private var logoutPending: Bool { flagStore.pendingLogout(installationId: installationId) != nil }

    /// Ждём, пока первая регистрация уйдёт в сеть (стенд пишет запрос до паузы ответа).
    private func waitForRegisters(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while StubURLProtocol.requests(path: registerPath).count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, count, "регистрация в полёте")
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
            sessionConfiguration: .stubbed(),
            flagStore: flagStore
        )
    }

    /// `unlinked: nil` — ответ старого сервера, который поля не знает.
    private func stubRegister(
        jwt: String = "jwt-1",
        expiresIn: Int = 900,
        identityStatus: String = "not_provided",
        unlinked: Bool? = nil,
        delay: TimeInterval = 0
    ) {
        var identity: [String: Any] = ["status": identityStatus]
        if let unlinked { identity["unlinked"] = unlinked }
        var response = StubResponse.json([
            "deviceId": "42",
            "jwt": jwt,
            "expiresIn": expiresIn,
            "attestationRequired": false,
            "identity": identity,
        ])
        response.chunkDelay = delay
        StubURLProtocol.enqueue(path: registerPath, response)
    }

    private func registerBodies() -> [[String: Any]] {
        StubURLProtocol.requests(path: registerPath).compactMap(\.body)
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

    // MARK: Выход

    /// Выход — отдельное поле, а не `identityToken: null`: у сервера токен — строка, и `null`
    /// вернул бы 400.
    func testВыходУходитВСледующуюРегистрациюБезIdentityТокена() async throws {
        stubRegister(unlinked: true)
        let client = makeClient()
        await client.setIdentityToken("token.of.a")

        await client.logout()
        _ = try await client.openSession()

        let body = try XCTUnwrap(registerBodies().first)
        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertNil(body["identityToken"], "токен вышедшего пользователя не уходит")
    }

    func testБезВыходаПоляLogoutВЗапросеНет() async throws {
        stubRegister(unlinked: false)
        _ = try await makeClient().openSession()

        let body = try XCTUnwrap(registerBodies().first)
        XCTAssertNil(body["logout"])
    }

    func testПодтверждённыйСерверомВыходСнимаетФлаг() async throws {
        stubRegister(jwt: "jwt-1", unlinked: true)
        stubRegister(jwt: "jwt-2", unlinked: false)
        let client = makeClient()

        await client.logout()
        _ = try await client.openSession()
        _ = try await client.openSession()

        XCTAssertEqual(registerBodies().map { $0["logout"] as? Bool }, [true, nil])
        XCTAssertFalse(logoutPending)
    }

    /// Старый сервер поле `logout` игнорирует и `unlinked` не присылает. Снять флаг по
    /// такому ответу — значит потерять выход навсегда: после обновления сервера его уже
    /// некому будет прислать.
    func testСтарыйСерверНеСнимаетФлагИВыходШлётсяСнова() async throws {
        stubRegister(jwt: "jwt-1")
        stubRegister(jwt: "jwt-2")
        let client = makeClient()

        await client.logout()
        _ = try await client.openSession()
        _ = try await client.openSession()

        XCTAssertEqual(registerBodies().map { $0["logout"] as? Bool }, [true, true])
        XCTAssertTrue(logoutPending)
    }

    /// Регистрация ленивая: выход до `configure()` или перед убийством приложения доходит
    /// только флагом на диске.
    func testФлагВыходаИзПрошлогоЗапускаУходитВПервуюРегистрацию() async throws {
        flagStore.markLogout(installationId: installationId)
        stubRegister(unlinked: true)

        _ = try await makeClient().openSession()

        XCTAssertEqual(registerBodies().first?["logout"] as? Bool, true)
        XCTAssertFalse(logoutPending)
    }

    /// Флаг прежней установки (после `reset()` или гонки записи с ним) к новой не относится:
    /// отправь его — сервер отвязал бы уже новую связь.
    func testФлагДругойУстановкиНеУходитИСтирается() async throws {
        flagStore.markLogout(installationId: "00000000-0000-4000-8000-000000000000")
        stubRegister(unlinked: false)

        _ = try await makeClient().openSession()

        XCTAssertNil(registerBodies().first?["logout"])
        XCTAssertNil(defaults.string(forKey: IdentityFlagStore.pendingLogoutKey))
    }

    /// Выход, записанный, пока летела регистрация с прежним выходом, её ответом не снимается:
    /// сервер подтвердил тот, что получил, а не этот.
    func testНовыйВыходЗаписанныйВПолётеНеСнимаетсяОтветомПрежнего() async throws {
        flagStore.markLogout(installationId: installationId)
        stubRegister(unlinked: true, delay: 0.3)
        let client = makeClient()

        async let session = client.openSession()
        try await waitForRegisters(1)
        flagStore.markLogout(installationId: installationId)
        _ = try await session

        XCTAssertTrue(logoutPending)
    }

    /// Ответ отброшен из-за смены identity — выход он не подтверждает, даже если нёс `unlinked`.
    func testОтброшенныйОтветНеСнимаетФлаг() async throws {
        stubRegister(jwt: "jwt-linked", unlinked: true, delay: 0.3)
        stubRegister(jwt: "jwt-2") // старый сервер: `unlinked` нет
        let client = makeClient()
        await client.logout()

        async let token = client.validToken()
        try await waitForRegisters(1)
        await client.setIdentityToken("token.of.b")
        let value = try await token

        XCTAssertEqual(value, "jwt-2")
        XCTAssertEqual(registerBodies().map { $0["logout"] as? Bool }, [true, true])
        XCTAssertTrue(logoutPending, "подтверждения, относящегося к текущей identity, не было")
    }

    /// Хост выпускает свежий токен на каждый вход в чат. Два таких вызова во время отправки
    /// раньше исчерпывали попытки регистрации, и сообщение не уходило.
    func testСвежийТокенТогоЖеЧеловекаНеОтбрасываетРегистрациюВПолёте() async throws {
        // Первый токен экземпляра ставит выход; сервер его подтверждает в первом же ответе.
        stubRegister(jwt: "jwt-first", identityStatus: "stale", unlinked: true, delay: 0.3)
        stubRegister(jwt: "jwt-fresh", identityStatus: "verified")
        let client = makeClient()
        await client.setIdentityToken(makeIdentityJWT(sub: "user-42", iat: 1))

        async let token = client.validToken()
        try await waitForRegisters(1)
        await client.setIdentityToken(makeIdentityJWT(sub: "user-42", iat: 2))
        await client.setIdentityToken(makeIdentityJWT(sub: "user-42", iat: 3))
        let value = try await token

        XCTAssertEqual(value, "jwt-first", "связь того же человека — ждущий запрос получает ответ")
        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 1)

        let next = try await client.validToken()
        XCTAssertEqual(next, "jwt-fresh", "ответ со старым токеном не закэширован — свежий дошёл до сервера")
        XCTAssertEqual(
            registerBodies().last?["identityToken"] as? String,
            makeIdentityJWT(sub: "user-42", iat: 3)
        )
        XCTAssertNil(registerBodies().last?["logout"], "обновление токена — не смена человека")
        XCTAssertFalse(logoutPending)
    }

    /// Ответ регистрации, ушедшей со старым токеном того же человека, не кэшируется — и его
    /// статус тоже не публикуется: `stale` устаревшего токена хост принял бы за провал свежего.
    func testСтатусРегистрацииСоСтарымТокеномНеПубликуется() async throws {
        stubRegister(jwt: "jwt-first", identityStatus: "stale", unlinked: true, delay: 0.3)
        stubRegister(jwt: "jwt-fresh", identityStatus: "verified")
        let client = makeClient()
        await client.setIdentityToken(makeIdentityJWT(sub: "user-42", iat: 1))

        async let token = client.validToken()
        try await waitForRegisters(1)
        await client.setIdentityToken(makeIdentityJWT(sub: "user-42", iat: 2))
        _ = try await token

        let afterSuperseded = await client.identityStatus
        XCTAssertEqual(afterSuperseded, .notProvided, "статус старого токена не публикуется")
        _ = try await client.validToken()
        let afterFresh = await client.identityStatus
        XCTAssertEqual(afterFresh, .verified)
    }

    /// `sub` не читается — сервер такой токен отклонит и связь не тронет. Без флага устройство
    /// осталось бы за прежним, и новый человек читал бы его тред.
    func testТокенБезSubПоверхПрежнегоСтавитВыход() async throws {
        stubRegister(identityStatus: "verified", unlinked: true)
        let client = makeClient()
        await client.setIdentityToken(makeIdentityJWT(sub: "user-a"))
        _ = try await client.openSession()
        XCTAssertFalse(logoutPending, "выход первого токена подтверждён")

        await client.setIdentityToken("not-a-jwt")

        XCTAssertTrue(logoutPending)
    }

    /// Другой `sub` поверх прежнего без выхода: связь прежнего рвётся, даже если токен
    /// нового сервер не примет, — иначе новый увидел бы тред прежнего.
    func testДругойЧеловекПоверхПрежнегоСтавитВыходИСбрасываетДиалог() async throws {
        stubRegister(identityStatus: "stale", unlinked: true)
        let client = makeClient()
        await client.setIdentityToken(makeIdentityJWT(sub: "user-a"))
        XCTAssertTrue(logoutPending, "первый токен экземпляра: кто был связан до него, неизвестно")
        await client.setConversationId(77)

        await client.setIdentityToken(makeIdentityJWT(sub: "user-b"))

        XCTAssertTrue(logoutPending)
        let conversationId = await client.conversationId
        XCTAssertNil(conversationId, "диалог прежнего человека")
        _ = try await client.openSession()
        let body = try XCTUnwrap(registerBodies().first)
        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertEqual(body["identityToken"] as? String, makeIdentityJWT(sub: "user-b"))
        XCTAssertFalse(logoutPending)
    }

    func testВыходИНовыйТокенУходятВОднойРегистрации() async throws {
        stubRegister(identityStatus: "verified", unlinked: true)
        let client = makeClient()

        await client.logout()
        await client.setIdentityToken("token.of.b")
        _ = try await client.openSession()

        let body = try XCTUnwrap(registerBodies().first)
        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertEqual(body["identityToken"] as? String, "token.of.b")
    }

    /// Регистрация ушла ДО выхода и вернула JWT устройства, ещё связанного с вышедшим
    /// пользователем. Сохрани клиент его — чат ходил бы под чужой связью до истечения токена.
    func testРегистрацияНачатаяДоВыходаНеОставляетСтарыйJWT() async throws {
        stubRegister(jwt: "jwt-linked", delay: 0.3)
        stubRegister(jwt: "jwt-after-logout", unlinked: true)
        let client = makeClient()

        async let token = client.validToken()
        try await waitForRegisters(1)

        await client.logout()
        let value = try await token

        XCTAssertEqual(value, "jwt-after-logout")
        XCTAssertEqual(registerBodies().map { $0["logout"] as? Bool }, [nil, true])
        let reused = try await client.validToken()
        XCTAssertEqual(reused, "jwt-after-logout", "сохранён токен новой регистрации, не прежней")
        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 2)
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

    /// Строку устройства увёл в отставку выход (например, на другой копии клиента) — токен
    /// указывает на устройство, которого нет. Лечится новой регистрацией, как `jwt_*`.
    func testСнятоеУстройствоВИсторииПеререгистрируетсяИЗапросПовторяется() async throws {
        stubRegister(jwt: "jwt-old")
        stubRegister(jwt: "jwt-new")
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "error": ["type": "authentication_error", "code": "device_not_found", "message": "gone"],
            ], status: 401),
            .json(["messages": [], "hasMore": false, "mode": "ai"])
        )

        let page = try await makeClient().history()

        XCTAssertTrue(page.messages.isEmpty)
        let requests = StubURLProtocol.requests(path: messagesPath)
        XCTAssertEqual(requests.count, 2, "ровно одна повторная попытка")
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer jwt-new")
        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 2)
    }

    func testСнятоеУстройствоВПотокеПеререгистрируетсяИЗапросПовторяется() async throws {
        stubRegister(jwt: "jwt-old")
        stubRegister(jwt: "jwt-new")
        StubURLProtocol.enqueue(
            path: streamPath,
            .json([
                "error": ["type": "authentication_error", "code": "device_claim_missing", "message": "old"],
            ], status: 401),
            .sse("data: [DONE]\n\n")
        )

        let (events, error) = await collect(makeClient().sendMessage("привет"))

        XCTAssertNil(error)
        XCTAssertEqual(events, [.done])
        let requests = StubURLProtocol.requests(path: streamPath)
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["Bearer jwt-old", "Bearer jwt-new"])
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

    // MARK: Идемпотентная отправка (`clientMessageId`)

    private func collectInternal(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> (events: [StreamEvent], error: Error?) {
        var events: [StreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private let clientId = "a1b2c3d4-0000-4000-8000-000000000042"

    func testIdУходитВТелеЗапросаИПодтверждениеПриходитОтдельнымСобытием() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .sse(
                "event: meta\ndata: {\"conversationId\":5,\"mode\":\"ai\",\"clientMessageId\":\"\(clientId)\","
                    + "\"userMessageId\":301,\"replayed\":false}\n\ndata: [DONE]\n\n"
            )
        )

        let client = makeClient()
        let (events, error) = await collectInternal(client.sendMessage("вопрос", clientMessageId: clientId))

        XCTAssertNil(error)
        XCTAssertEqual(
            events,
            [
                .event(.meta(conversationId: 5, mode: .ai)),
                .accepted(StreamAcceptance(clientMessageId: clientId, userMessageId: 301, replayed: false)),
                .event(.done),
            ]
        )
        let request = try XCTUnwrap(StubURLProtocol.requests(path: streamPath).first)
        XCTAssertEqual(request.body?["clientMessageId"] as? String, clientId)
        XCTAssertEqual(request.body?["clientMessageId"] as? String, clientId.lowercased())
    }

    /// Публичная отправка идентификатора не несёт (у хоста своих локальных строк нет) — тело
    /// остаётся прежним, как у 0.2.8.
    func testПубличнаяОтправкаТелоНеМеняет() async throws {
        stubRegister()
        StubURLProtocol.enqueue(path: streamPath, .sse("data: [DONE]\n\n"))

        _ = await collect(makeClient().sendMessage("вопрос"))

        let request = try XCTUnwrap(StubURLProtocol.requests(path: streamPath).first)
        XCTAssertNil(request.body?["clientMessageId"])
    }

    /// Перерегистрация по 401 обязана повторить ТОТ ЖЕ идентификатор: другой превратил бы
    /// повтор в второе сообщение (и вторую платную генерацию).
    func testПовторПо401НесётТотЖеId() async throws {
        stubRegister(jwt: "jwt-old")
        stubRegister(jwt: "jwt-new")
        StubURLProtocol.enqueue(
            path: streamPath,
            .json([
                "error": ["type": "authentication_error", "code": "jwt_expired", "message": "JWT expired"],
            ], status: 401),
            .sse("data: [DONE]\n\n")
        )

        let (_, error) = await collectInternal(makeClient().sendMessage("вопрос", clientMessageId: clientId))

        XCTAssertNil(error)
        let ids = StubURLProtocol.requests(path: streamPath).map { $0.body?["clientMessageId"] as? String }
        XCTAssertEqual(ids, [clientId, clientId])
    }

    /// Поддержка определяется НАЛИЧИЕМ ключа, а не значением: у строки, записанной до 0.2.9,
    /// он приходит как `null` — и это всё равно «сервер умеет».
    func testИсторияЧитаетIdИОпределяетПоддержкуПоНаличиюКлюча() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [
                    ["id": 10, "role": "user", "content": "привет", "clientMessageId": NSNull()],
                    ["id": 11, "role": "user", "content": "и ещё", "clientMessageId": clientId],
                    ["id": 12, "role": "assistant", "content": "Здравствуйте!"],
                ],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let page = try await makeClient().history()

        XCTAssertEqual(page.messages.map(\.clientMessageId), [nil, clientId, nil])
        XCTAssertTrue(page.clientMessageIdsSupported)
    }

    /// Старый сервер ключа не отдаёт вовсе — экран остаётся на сопоставлении по тексту.
    func testСтарыйСерверПоддержкуНеОбъявляет() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [["id": 10, "role": "user", "content": "привет"]],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let page = try await makeClient().history()

        XCTAssertNil(page.messages.first?.clientMessageId)
        XCTAssertFalse(page.clientMessageIdsSupported)
    }

    /// Ключ только у строк пользователя: у ответа ассистента его нет и быть не может.
    func testКлючУАссистентаПоддержкуНеОбъявляет() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json([
                "messages": [["id": 11, "role": "assistant", "content": "Ответ", "clientMessageId": NSNull()]],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let page = try await makeClient().history()

        XCTAssertFalse(page.clientMessageIdsSupported)
    }

    // MARK: Порядок смен identity (`identitySeq`)

    func testНомерСменыIdentityУходитВРегистрацию() async throws {
        stubRegister(unlinked: true)
        let client = makeClient()

        await client.logout()
        _ = try await client.openSession()

        let body = try XCTUnwrap(registerBodies().first)
        XCTAssertEqual(body["identitySeq"] as? Int, 1, "выход поднял счётчик в той же критической секции")
    }

    func testБезСменIdentityНомерНуль() async throws {
        stubRegister()
        _ = try await makeClient().openSession()

        XCTAssertEqual(registerBodies().first?["identitySeq"] as? Int, 0)
    }

    /// Счётчик отстал (настройки восстановили из бэкапа) — сервер называет свой номер, и это
    /// значит, что для identity он запрос НЕ применил. Поднимаем счётчик и повторяем: иначе
    /// выход так и висел бы неприменённым, а хост считал бы его доставленным.
    func testСерверныйНомерБольшеПоднимаетСчётчикИРегистрацияПовторяется() async throws {
        StubURLProtocol.enqueue(
            path: registerPath,
            .json([
                "deviceId": "42",
                "jwt": "jwt-discarded",
                "expiresIn": 900,
                "identity": ["status": "not_provided", "unlinked": true, "seq": 7],
            ]),
            .json([
                "deviceId": "42",
                "jwt": "jwt-applied",
                "expiresIn": 900,
                "identity": ["status": "not_provided", "unlinked": true, "seq": 7],
            ])
        )
        let client = makeClient()
        await client.logout()

        let session = try await client.openSession()

        XCTAssertEqual(session.jwt, "jwt-applied")
        XCTAssertEqual(
            registerBodies().map { $0["identitySeq"] as? Int },
            [1, 7],
            "второе тело уходит с номером, который сервер примет"
        )
        XCTAssertFalse(logoutPending, "выход подтверждён только принятым запросом")
    }

    /// Ответ отброшен — флаг выхода остаётся: сервер его не применил. Номер в каждом ответе
    /// выше предыдущего, поэтому не проходит ни одна попытка.
    func testОтброшенныйПоНомеруОтветНеСнимаетФлагВыхода() async throws {
        for seq in [9, 11] {
            StubURLProtocol.enqueue(
                path: registerPath,
                .json([
                    "deviceId": "42",
                    "jwt": "jwt-discarded",
                    "expiresIn": 900,
                    "identity": ["status": "not_provided", "unlinked": true, "seq": seq],
                ])
            )
        }
        let client = makeClient()
        await client.logout()

        do {
            _ = try await client.openSession()
            XCTFail("ожидалась отмена: ни одна попытка не применена")
        } catch {
            XCTAssertEqual((error as? MeerBotError)?.code, "cancelled")
        }
        XCTAssertTrue(logoutPending)
    }

    /// Старый сервер номера не присылает — поведение прежнее, повторов нет.
    func testОтветБезНомераПовторовНеВызывает() async throws {
        stubRegister(unlinked: true)
        let client = makeClient()
        await client.logout()

        _ = try await client.openSession()

        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 1)
        XCTAssertFalse(logoutPending)
    }

    // MARK: Сервер занят (503)

    /// 503 сервер отдаёт при перезапуске и сам называет паузу. `Retry-After: 0` — готов
    /// сразу: тест детерминирован, потому что джиттер пропорционален паузе.
    func testЗанятыйСерверПовторяетсяОдинРазПослеУказаннойПаузы() async throws {
        var busy = StubResponse.json([
            "error": ["type": "server_error", "code": "service_unavailable", "message": "restarting"],
        ], status: 503)
        busy.headers["Retry-After"] = "0"
        StubURLProtocol.enqueue(path: registerPath, busy)
        stubRegister(jwt: "jwt-after-restart")

        let session = try await makeClient().openSession()

        XCTAssertEqual(session.jwt, "jwt-after-restart")
        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 2)
    }

    /// Второй отказ уходит наверх: дальше ждать — это держать пользователя на пустом экране.
    func testВторойОтказЗанятогоСервераДоходитДоХоста() async {
        var busy = StubResponse.json([
            "error": ["type": "server_error", "code": "service_unavailable", "message": "restarting"],
        ], status: 503)
        busy.headers["Retry-After"] = "0"
        StubURLProtocol.enqueue(path: registerPath, busy) // единственный ответ повторяется

        do {
            _ = try await makeClient().openSession()
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual((error as? MeerBotError)?.code, "service_unavailable")
        }
        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 2, "ровно один повтор")
    }

    func testПаузаПередПовторомСчитаетсяПоЗаголовкуСПотолкомИДжиттером() {
        // Заголовка нет — секунда: заметно меньше потолка и не попадает в тот же миг перезапуска.
        XCTAssertEqual(APIClient.unavailableRetryDelay(retryAfter: nil, jitter: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(APIClient.unavailableRetryDelay(retryAfter: "not-a-number", jitter: 0), 1, accuracy: 0.0001)
        // Потолок: дольше ждать молча нельзя.
        XCTAssertEqual(
            APIClient.unavailableRetryDelay(retryAfter: "600", jitter: 1),
            APIClient.unavailableRetryCap * 1.1,
            accuracy: 0.0001
        )
        XCTAssertEqual(APIClient.unavailableRetryDelay(retryAfter: "-5", jitter: 1), 0, accuracy: 0.0001)
        // Джиттер пропорционален паузе: при `Retry-After: 0` ожидание не выдумывается.
        XCTAssertEqual(APIClient.unavailableRetryDelay(retryAfter: "0", jitter: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(APIClient.unavailableRetryDelay(retryAfter: " 2 ", jitter: 0.5), 2.1, accuracy: 0.0001)
        XCTAssertEqual(APIClient.unavailableRetryDelay(retryAfter: "2", jitter: 5), 2.2, accuracy: 0.0001)
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
