// Поведение экрана: что видит пользователь при нормальном ответе, при обрыве связи
// и при повторной отправке.

import XCTest
@testable import MeerBotSDK

@MainActor
final class ChatControllerTests: XCTestCase {

    private let registerPath = "/api/v1/mobile/register"
    private let streamPath = "/api/v1/mobile/chat/stream"
    private let messagesPath = "/api/v1/mobile/messages"

    /// Свой домен настроек: смена identity пишет флаг выхода на диск, и `.standard` пронёс
    /// бы его в соседние тесты и следующий прогон.
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        suiteName = "MeerBotSDKTests.ChatController.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeClient() -> APIClient {
        APIClient(
            config: MeerBotConfiguration(
                apiKey: "pk_live_test",
                baseURL: URL(string: "https://meerbot.test")!
            ),
            visitorUuid: "11111111-2222-4333-8444-555555555555",
            installationId: "99999999-8888-4777-8666-555555555555",
            sessionConfiguration: .stubbed(),
            flagStore: IdentityFlagStore(defaults: defaults)
        )
    }

    private func makeController() -> ChatController {
        ChatController(client: makeClient())
    }

    private func stubRegister() {
        StubURLProtocol.enqueue(
            path: registerPath,
            .json([
                "deviceId": "42",
                "jwt": "jwt-1",
                "expiresIn": 900,
                "attestationRequired": false,
                "identity": ["status": "not_provided"],
            ])
        )
    }

    private func stubHistory(_ messages: [[String: Any]] = [], mode: String = "ai") {
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json(["messages": messages, "hasMore": false, "mode": mode])
        )
    }

    /// Ждём выполнения условия, не завязываясь на конкретные тайминги планировщика.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("не дождались: \(description)")
    }

    // MARK: Старт

    func testСтартРегистрируетУстройствоИПодтягиваетТред() async throws {
        stubRegister()
        stubHistory([
            ["id": 1, "role": "user", "content": "вчерашний вопрос", "createdAt": "2026-08-15T10:00:00.000Z"],
            ["id": 2, "role": "assistant", "content": "вчерашний ответ", "createdAt": "2026-08-15T10:00:01.000Z"],
        ])

        let controller = makeController()
        controller.start()

        try await waitUntil("готовности сессии") { controller.isReady }
        XCTAssertEqual(
            controller.store.messages.map(\.content),
            ["вчерашний вопрос", "вчерашний ответ"],
            "история треда — по устройству, id диалога для этого не нужен"
        )
        XCTAssertNil(controller.store.connectionError)
    }

    /// «Диалог у менеджера» — состояние ТРЕДА, а не свойство сообщений. Не примени мы режим
    /// при пустой ленте, экран предлагал бы писать боту, который в этом режиме молчит.
    func testРежимТредаПрименяетсяДажеПриПустойЛенте() async throws {
        stubRegister()
        stubHistory([], mode: "human")

        let controller = makeController()
        controller.start()

        try await waitUntil("готовности сессии") { controller.isReady }
        XCTAssertEqual(controller.store.mode, .human)
    }

    func testОтказРегистрацииПоказываетсяПользователюИНеОставляетЭкранГотовым() async throws {
        StubURLProtocol.enqueue(
            path: registerPath,
            .json([
                "error": ["type": "authentication_error", "code": "identity_required", "message": "нужен вход"],
            ], status: 403)
        )

        let controller = makeController()
        controller.start()

        try await waitUntil("баннера ошибки") { controller.store.connectionError != nil }
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.store.connectionError, "Приложение требует входа. Войдите и повторите.")
    }

    // MARK: Поток

    func testОтветСтримитсяВЛентуИЗавершается() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .sse(
                """
                event: meta
                data: {"conversationId":5,"mode":"ai"}

                data: {"choices":[{"delta":{"content":"Всё "}}]}

                data: {"choices":[{"delta":{"content":"работает"}}]}

                data: [DONE]


                """
            )
        )

        let controller = makeController()
        controller.send("привет")

        try await waitUntil("завершения ответа") { !controller.store.sending }
        XCTAssertEqual(controller.store.messages.map(\.content), ["привет", "Всё работает"])
        XCTAssertEqual(controller.store.messages.last?.streaming, false)
        XCTAssertNil(controller.store.connectionError)
    }

    func testОбрывСетиПоказываетОшибкуИПредлагаетПовтор() async throws {
        stubRegister()
        var dropped = StubResponse.sse("data: {\"choices\":[{\"delta\":{\"content\":\"частичный\"}}]}\n\n")
        dropped.failure = URLError(.networkConnectionLost)
        dropped.chunkDelay = 0.05
        StubURLProtocol.enqueue(path: streamPath, dropped)

        let controller = makeController()
        controller.send("привет")

        try await waitUntil("появления баннера ошибки") { controller.store.connectionError != nil }
        XCTAssertFalse(controller.store.sending)
        XCTAssertEqual(controller.retryableText, "привет", "текст сохранён для повтора")
        XCTAssertEqual(
            controller.store.messages.first(where: { $0.role == "user" })?.failed,
            true,
            "сообщение помечено недоставленным"
        )
        XCTAssertTrue(
            controller.store.messages.contains { $0.content == "частичный" },
            "уже полученный кусок ответа не выбрасываем"
        )
    }

    func testПовторПослеОбрываДоводитОтветДоКонца() async throws {
        stubRegister()
        var dropped = StubResponse.sse("")
        dropped.failure = URLError(.networkConnectionLost)
        StubURLProtocol.enqueue(
            path: streamPath,
            dropped,
            .sse("data: {\"choices\":[{\"delta\":{\"content\":\"Готово\"}}]}\n\ndata: [DONE]\n\n")
        )

        let controller = makeController()
        controller.send("привет")
        try await waitUntil("первой ошибки") { controller.retryableText != nil }

        controller.retry()
        try await waitUntil("успешного повтора") {
            controller.store.messages.last?.content == "Готово" && !controller.store.sending
        }
        XCTAssertEqual(controller.store.messages.filter { $0.role == "user" }.count, 1, "дубль не создаётся")
        XCTAssertEqual(controller.store.messages.first?.failed, false, "пометка снята")
    }

    /// Если соединение оборвалось, но сервер успел дописать ответ — состояние берём с сервера.
    func testПослеОбрываЛентаПодтягиваетсяСервернойИсторией() async throws {
        stubRegister()
        var dropped = StubResponse.sse("event: meta\ndata: {\"conversationId\":31,\"mode\":\"ai\"}\n\n")
        dropped.failure = URLError(.networkConnectionLost)
        dropped.chunkDelay = 0.05
        StubURLProtocol.enqueue(path: streamPath, dropped)
        stubHistory([
            ["id": 1, "role": "user", "content": "привет", "createdAt": "2026-08-15T10:00:00.000Z"],
            ["id": 2, "role": "assistant", "content": "Ответ дописан", "createdAt": "2026-08-15T10:00:01.000Z"],
        ])

        let controller = makeController()
        controller.send("привет")

        try await waitUntil("догона истории") {
            controller.store.messages.last?.content == "Ответ дописан"
        }
        XCTAssertNil(controller.retryableText, "повторять нечего — ответ уже есть")
    }

    func testЗакрытыйДиалогНеПринимаетСообщения() async throws {
        stubRegister()
        let controller = makeController()
        controller.store.setMode(.closed)
        controller.send("привет")

        XCTAssertTrue(controller.store.messages.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests(path: streamPath).isEmpty)
    }

    func testПушПодтягиваетСвежуюЛенту() async throws {
        stubRegister()
        stubHistory([
            ["id": 7, "role": "assistant", "content": "Менеджер ответил", "createdAt": "2026-08-15T10:00:00.000Z"],
        ], mode: "human")

        let controller = makeController()
        controller.openConversation(id: 55)

        try await waitUntil("загрузки ленты после пуша") {
            controller.store.messages.last?.content == "Менеджер ответил"
        }
    }

    /// Тот же пуш, но проверяем ПОДПИСЬ: ответ менеджера, прочитанный из истории, обязан
    /// остаться ответом менеджера. Экран рисует автора по этому полю, и до 2026-08-23
    /// пользователь после возврата в приложение видел живого оператора как бота.
    func testОтветМенеджераИзИсторииНеВыглядитОтветомБота() async throws {
        stubRegister()
        stubHistory([
            ["id": 7, "role": "assistant", "content": "Я бот", "authorKind": "ai"],
            [
                "id": 8,
                "role": "assistant",
                "content": "Разберусь с подпиской",
                "authorKind": "manager",
                "authorName": "Роман",
            ],
        ], mode: "human")

        let controller = makeController()
        controller.openConversation(id: 55)

        try await waitUntil("загрузки ленты") { controller.store.messages.count == 2 }
        XCTAssertEqual(controller.store.messages.map(\.author), ["ai", "manager"])
        XCTAssertEqual(controller.store.messages.last?.authorName, "Роман")
    }

    /// `refresh()` перечитывает ТЕКУЩИЙ тред — в отличие от `openConversation(id:)`,
    /// которому нужен id из пуша. Пуш канала приходить без id имеет право: тред у мобильного
    /// пользователя один, и бэкенд интегратора адресует его своим `external_user_id`.
    func testRefreshПодтягиваетЛентуБезIdДиалога() async throws {
        stubRegister()
        stubHistory()

        // Оба ответа кладутся ЗАРАНЕЕ: очередь стаба отдаёт их по порядку, а последний
        // повторяет. Досыпать второй ответ после старта нельзя — стартовый (пустой) остался
        // бы первым в очереди и достался бы как раз `refresh()`.
        stubHistory([
            ["id": 12, "role": "assistant", "content": "Менеджер ответил", "authorKind": "manager"],
        ], mode: "human")

        let controller = makeController()
        controller.start()
        try await waitUntil("готовности сессии") { controller.isReady }
        XCTAssertTrue(controller.store.messages.isEmpty, "на старте лента ещё пуста")

        controller.refresh()

        try await waitUntil("обновления ленты") {
            controller.store.messages.last?.author == "manager"
        }
        XCTAssertNil(controller.conversationId, "refresh не выдумывает id диалога")
    }

    // MARK: - conversationId наружу

    // Приложение хоста получает пуш «менеджер ответил» СВОИМ бэкендом (платформа шлёт вебхук,
    // а не пуш) и должно уметь подавить баннер, когда этот же диалог открыт на экране.
    // Сравнивать было не с чем: id жил внутри APIClient и на контроллер не выходил.

    func testДоПервогоСообщенияДиалогаНетИИдентификаторПуст() async throws {
        stubRegister()
        stubHistory()

        let controller = makeController()
        controller.start()

        try await waitUntil("готовности сессии") { controller.isReady }
        XCTAssertNil(
            controller.conversationId,
            "регистрация про диалог ничего не сообщает — id приходит из meta или из пуша"
        )
    }

    func testНовыйДиалогПоднимаетсяИзСобытияMeta() async throws {
        stubRegister()
        StubURLProtocol.enqueue(
            path: streamPath,
            .sse(
                """
                event: meta
                data: {"conversationId":5,"mode":"ai"}

                data: [DONE]


                """
            )
        )

        let controller = makeController()
        XCTAssertNil(controller.conversationId)
        controller.send("привет")

        try await waitUntil("завершения ответа") { !controller.store.sending }
        XCTAssertEqual(controller.conversationId, 5)
    }

    func testОткрытиеДиалогаИзПушаОбновляетИдентификатор() async throws {
        stubRegister()
        stubHistory()

        let controller = makeController()
        controller.openConversation(id: 42)

        try await waitUntil("применения диалога") { controller.conversationId == 42 }
    }

    // MARK: - Смена identity

    // До 0.2.9 выход не трогал ленту: `loadHistory` пропускает пустую страницу, и следующий
    // человек на телефоне видел переписку прежнего до перезапуска приложения.

    private let previousUserThread: [[String: Any]] = [
        ["id": 1, "role": "user", "content": "мой номер договора 123", "createdAt": "2026-09-01T10:00:00.000Z"],
        ["id": 2, "role": "assistant", "content": "Нашёл договор", "createdAt": "2026-09-01T10:00:01.000Z"],
    ]

    func testСменаIdentityОчищаетЛентуИОткрытыйЭкранПереподключаетсяСВыходом() async throws {
        stubRegister()
        stubHistory(previousUserThread) // старт
        // Пуш прежнему пользователю: ответ долетает уже ПОСЛЕ сброса — ровно тот случай,
        // когда отмена не помогает, а переписка прежнего человека легла бы в новую ленту.
        var latePushPage = StubResponse.json(["messages": previousUserThread, "hasMore": false, "mode": "ai"])
        latePushPage.chunkDelay = 0.3
        StubURLProtocol.enqueue(path: messagesPath, latePushPage)
        stubHistory() // новый тред после выхода

        let client = makeClient()
        let controller = ChatController(client: client)
        controller.store.setGreeting("Здравствуйте! Мы на связи.")
        controller.start()
        try await waitUntil("ленты прежнего пользователя") {
            controller.isReady && controller.store.messages.count == 2
        }
        controller.openConversation(id: 55)
        try await waitUntil("запроса истории по пушу") {
            controller.conversationId == 55 && StubURLProtocol.requests(path: self.messagesPath).count == 2
        }

        await client.logout()
        controller.resetForIdentityChange()

        XCTAssertTrue(controller.store.messages.isEmpty, "лента прежнего пользователя стёрта сразу")
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.conversationId)
        XCTAssertEqual(controller.store.greeting, "Здравствуйте! Мы на связи.", "приветствие задаёт хост")

        try await waitUntil("переподключения") { controller.isReady }
        // Ждём, пока запоздалый ответ по пушу гарантированно долетит.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(controller.store.messages.isEmpty, "пустой новый тред не возвращает старую ленту")
        let registers = StubURLProtocol.requests(path: registerPath)
        XCTAssertEqual(registers.count, 2, "открытый экран перерегистрировался")
        XCTAssertEqual(registers.last?.body?["logout"] as? Bool, true)
    }

    func testСменаIdentityНаЗакрытомЭкранеНеХодитВСеть() async throws {
        stubRegister()
        stubHistory(previousUserThread)

        let controller = makeController()
        controller.start()
        try await waitUntil("ленты прежнего пользователя") {
            controller.isReady && controller.store.messages.count == 2
        }
        controller.stop()
        let requestsBefore = StubURLProtocol.requests.count

        controller.resetForIdentityChange()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(controller.store.messages.isEmpty)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(StubURLProtocol.requests.count, requestsBefore, "сессия поднимется при следующем показе")
    }

    /// По `sub` решается, сменился ли человек: токены живут минуты, и сравнение строк чистило
    /// бы ленту на каждом свежем токене того же пользователя.
    func testСубъектIdentityТокенаЧитаетсяИзPayload() {
        func jwt(_ payload: String) -> String {
            let encoded = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(encoded).signature"
        }

        XCTAssertEqual(MeerBot.identitySubject(of: jwt(#"{"sub":"user-42","iat":1}"#)), "user-42")
        XCTAssertNil(MeerBot.identitySubject(of: jwt(#"{"iat":1}"#)), "без sub — сравнение по токену")
        XCTAssertNil(MeerBot.identitySubject(of: "not-a-jwt"))
        // Сервер обрезает `sub` (`identity-token.ts`): для него это один человек.
        XCTAssertEqual(MeerBot.identitySubject(of: jwt(#"{"sub":"  user-42 \n","iat":1}"#)), "user-42")
        XCTAssertNil(MeerBot.identitySubject(of: jwt(#"{"sub":"   ","iat":1}"#)))
    }

    // MARK: - Сообщение не теряется молча

    /// Регистрация не успела дважды: identity сменили во время обеих попыток, а эпоха
    /// контроллера та же (клиентом управляют напрямую). Раньше `.cancelled` глотался, и
    /// отправленное сообщение не было ни доставлено, ни помечено.
    func testИсчерпанныеПопыткиРегистрацииПомечаютСообщениеНедоставленным() async throws {
        var slowRegister = StubResponse.json([
            "deviceId": "42", "jwt": "jwt-1", "expiresIn": 900, "identity": ["status": "not_provided"],
        ])
        slowRegister.chunkDelay = 0.3
        StubURLProtocol.enqueue(path: registerPath, slowRegister)
        let client = makeClient()
        let controller = ChatController(client: client)

        controller.send("привет")
        try await waitUntil("первой регистрации") { StubURLProtocol.requests(path: self.registerPath).count == 1 }
        await client.setIdentityToken("token.of.a")
        try await waitUntil("второй регистрации") { StubURLProtocol.requests(path: self.registerPath).count == 2 }
        await client.setIdentityToken("token.of.b")

        try await waitUntil("пометки недоставленным") { controller.retryableText != nil }
        XCTAssertEqual(controller.retryableText, "привет")
        XCTAssertEqual(controller.store.messages.first(where: { $0.role == "user" })?.failed, true)
        XCTAssertEqual(controller.store.connectionError, "Запрос не выполнен. Попробуйте ещё раз.")
        XCTAssertFalse(controller.store.sending)
        XCTAssertTrue(StubURLProtocol.requests(path: streamPath).isEmpty)
    }

    /// Окно между очисткой ленты и применением identity к клиенту: сообщение из этого окна
    /// раньше уходило с прежней identity (или в новый тред) и стиралось сбросом, пришедшим следом.
    func testСообщениеВоВремяСменыIdentityЖдётЕёИНеСтирается() async throws {
        stubRegister()
        StubURLProtocol.enqueue(path: streamPath, .sse("data: {\"choices\":[{\"delta\":{\"content\":\"Ответ\"}}]}\n\ndata: [DONE]\n\n"))
        stubHistory()
        let controller = makeController()

        controller.beginIdentityChange()
        controller.send("привет")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.store.messages.map(\.content), ["привет"])
        XCTAssertTrue(controller.store.sending, "второе сообщение поверх ждущего не отправить")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "до применения identity в сеть не ходим")

        controller.finishIdentityChange()

        try await waitUntil("ответа на ждавшее сообщение") {
            controller.store.messages.last?.content == "Ответ" && !controller.store.sending
        }
        XCTAssertEqual(controller.store.messages.filter { $0.role == "user" }.map(\.content), ["привет"])
    }

    func testЗакрытиеЭкранаВоВремяСменыIdentityОставляетСообщениеКПовтору() async throws {
        let controller = makeController()

        controller.beginIdentityChange()
        controller.send("привет")
        controller.stop()
        controller.finishIdentityChange()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.retryableText, "привет")
        XCTAssertEqual(controller.store.messages.first?.failed, true)
        XCTAssertFalse(controller.store.sending)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// Эпоха берётся при ВЫЗОВЕ: взятая внутри задачи, она была бы уже новой, и id диалога
    /// из пуша прежнему пользователю лёг бы в сессию следующего.
    func testПушДоСменыIdentityНеОставляетIdДиалогаПрежнего() async throws {
        stubRegister()
        stubHistory()
        let client = makeClient()
        let controller = ChatController(client: client)

        controller.openConversation(id: 55)
        controller.resetForIdentityChange()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(controller.conversationId)
        let clientConversationId = await client.conversationId
        XCTAssertNil(clientConversationId)
        XCTAssertTrue(StubURLProtocol.requests(path: messagesPath).isEmpty)
    }
}
