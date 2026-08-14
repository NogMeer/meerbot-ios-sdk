// Поведение экрана: что видит пользователь при нормальном ответе, при обрыве связи
// и при повторной отправке.

import XCTest
@testable import MeerBotSDK

@MainActor
final class ChatControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeController() -> ChatController {
        ChatController(
            client: APIClient(
                config: MeerBotConfiguration(
                    apiKey: "pk_live_test",
                    baseURL: URL(string: "https://meerbot.test")!,
                    origin: "https://ru.tumanvpn.app"
                ),
                visitorUuid: "11111111-2222-4333-8444-555555555555",
                sessionConfiguration: .stubbed()
            )
        )
    }

    private func stubSession(conversationId: Any = NSNull()) {
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/session",
            .json([
                "sessionId": "s1",
                "jwt": "jwt-1",
                "expiresIn": 900,
                "conversationId": conversationId,
                "mode": "ai",
                "widget": ["id": 1, "title": "Поддержка", "greeting": "Чем помочь?"],
            ], status: 201)
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

    func testПриветствиеКаналаПоднимаетсяИзHandshake() async throws {
        stubSession()
        let controller = makeController()
        controller.start()

        try await waitUntil("готовности сессии") { controller.isReady }
        XCTAssertEqual(controller.store.greeting, "Чем помочь?")
        XCTAssertNil(controller.store.connectionError)
    }

    func testОтветСтримитсяВЛентуИЗавершается() async throws {
        stubSession()
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/chat/stream",
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
        stubSession()
        var dropped = StubResponse.sse("data: {\"choices\":[{\"delta\":{\"content\":\"частичный\"}}]}\n\n")
        dropped.failure = URLError(.networkConnectionLost)
        dropped.chunkDelay = 0.05
        StubURLProtocol.enqueue(path: "/api/v1/widget/chat/stream", dropped)

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
        stubSession()
        var dropped = StubResponse.sse("")
        dropped.failure = URLError(.networkConnectionLost)
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/chat/stream",
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
        stubSession()
        var dropped = StubResponse.sse("event: meta\ndata: {\"conversationId\":31,\"mode\":\"ai\"}\n\n")
        dropped.failure = URLError(.networkConnectionLost)
        dropped.chunkDelay = 0.05
        StubURLProtocol.enqueue(path: "/api/v1/widget/chat/stream", dropped)
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/messages",
            .json([
                "messages": [
                    ["id": 1, "role": "user", "content": "привет", "createdAt": "2026-08-11T10:00:00.000Z"],
                    ["id": 2, "role": "assistant", "content": "Ответ дописан", "createdAt": "2026-08-11T10:00:01.000Z"],
                ],
                "hasMore": false,
                "mode": "ai",
            ])
        )

        let controller = makeController()
        controller.send("привет")

        try await waitUntil("догона истории") {
            controller.store.messages.last?.content == "Ответ дописан"
        }
        XCTAssertNil(controller.retryableText, "повторять нечего — ответ уже есть")
    }

    func testЗакрытыйДиалогНеПринимаетСообщения() async throws {
        stubSession()
        let controller = makeController()
        controller.store.setMode(.closed)
        controller.send("привет")

        XCTAssertTrue(controller.store.messages.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests(path: "/api/v1/widget/chat/stream").isEmpty)
    }

    func testПушОткрываетДиалогИПодтягиваетЕгоИсторию() async throws {
        stubSession()
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/messages",
            .json([
                "messages": [["id": 7, "role": "assistant", "content": "Менеджер ответил", "createdAt": "2026-08-11T10:00:00.000Z"]],
                "hasMore": false,
                "mode": "human",
            ])
        )

        let controller = makeController()
        controller.openConversation(id: 55)

        try await waitUntil("загрузки истории диалога из пуша") {
            controller.store.messages.last?.content == "Менеджер ответил"
        }
    }

    // MARK: - conversationId наружу

    // Приложение хоста получает пуш «оператор ответил» своим бэкендом и должно уметь его
    // подавить, когда этот же диалог открыт на экране. Сравнивать было не с чем: id жил
    // внутри APIClient и на контроллер не выходил.

    func testДоПервогоСообщенияДиалогаНетИИдентификаторПуст() async throws {
        stubSession()
        let controller = makeController()
        controller.start()

        try await waitUntil("готовности сессии") { controller.isReady }
        XCTAssertNil(controller.conversationId)
    }

    func testВосстановленныйСерверомДиалогПоднимаетсяВHandshake() async throws {
        stubSession(conversationId: 77)
        StubURLProtocol.enqueue(path: "/api/v1/widget/messages", .json(["messages": []]))

        let controller = makeController()
        controller.start()

        try await waitUntil("готовности сессии") { controller.isReady }
        XCTAssertEqual(controller.conversationId, 77)
    }

    func testНовыйДиалогПоднимаетсяИзСобытияMeta() async throws {
        stubSession()
        StubURLProtocol.enqueue(
            path: "/api/v1/widget/chat/stream",
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
        StubURLProtocol.enqueue(path: "/api/v1/widget/messages", .json(["messages": []]))

        let controller = makeController()
        controller.openConversation(id: 42)

        try await waitUntil("применения диалога") { controller.conversationId == 42 }
    }

}
