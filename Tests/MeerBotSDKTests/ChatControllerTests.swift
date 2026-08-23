// Поведение экрана: что видит пользователь при нормальном ответе, при обрыве связи
// и при повторной отправке.

import XCTest
@testable import MeerBotSDK

@MainActor
final class ChatControllerTests: XCTestCase {

    private let registerPath = "/api/v1/mobile/register"
    private let streamPath = "/api/v1/mobile/chat/stream"
    private let messagesPath = "/api/v1/mobile/messages"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeController() -> ChatController {
        ChatController(
            client: APIClient(
                config: MeerBotConfiguration(
                    apiKey: "pk_live_test",
                    baseURL: URL(string: "https://meerbot.test")!
                ),
                visitorUuid: "11111111-2222-4333-8444-555555555555",
                installationId: "99999999-8888-4777-8666-555555555555",
                sessionConfiguration: .stubbed()
            )
        )
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

}
