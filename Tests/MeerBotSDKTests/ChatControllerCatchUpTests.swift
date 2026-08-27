// Догон ленты — единственный надёжный канал «менеджер ответил → пользователь увидел»:
// поток живёт только на время ответа бота, а пуш зависит от бэкенда интегратора.
//
// Периоды в тестах ужаты до миллисекунд: проверять шестисекундный тик ожиданием шести
// секунд — верный способ получить мигающий набор в релизном скрипте.

import XCTest
@testable import MeerBotSDK

@MainActor
final class ChatControllerCatchUpTests: XCTestCase {

    private let registerPath = "/api/v1/mobile/register"
    private let messagesPath = "/api/v1/mobile/messages"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        ChatController.managerPollInterval = 0.04
        ChatController.idlePollInterval = 0.04
    }

    override func tearDown() {
        ChatController.managerPollInterval = 6
        ChatController.idlePollInterval = 12
        super.tearDown()
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

    private func stubHistory(_ messages: [[String: Any]] = [], mode: String = "human") {
        StubURLProtocol.enqueue(
            path: messagesPath,
            .json(["messages": messages, "hasMore": false, "mode": mode])
        )
    }

    private func managerMessage(id: Int, text: String) -> [String: Any] {
        [
            "id": id,
            "role": "assistant",
            "content": text,
            "authorKind": "manager",
            "authorName": "Роман",
            "createdAt": "2026-08-25T10:00:00.000Z",
        ]
    }

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

    private func started() async throws -> ChatController {
        stubRegister()
        stubHistory()
        let controller = makeController()
        controller.start()
        try await waitUntil("готовности сессии") { controller.isReady }
        return controller
    }

    func testПоллингПодтягиваетОтветМенеджераБезОтправки() async throws {
        let controller = try await started()
        stubHistory([managerMessage(id: 9, text: "я тут")])

        try await waitUntil("ответа менеджера") {
            controller.store.messages.contains { $0.content == "я тут" }
        }
        XCTAssertEqual(controller.store.messages.last?.author, "manager")
        XCTAssertEqual(controller.store.messages.last?.authorName, "Роман")
    }

    func testДогонНесётКурсорSinceАНеТянетЛентуЦеликом() async throws {
        let controller = try await started()
        stubHistory([managerMessage(id: 9, text: "первое")])
        try await waitUntil("первой страницы") { !controller.store.messages.isEmpty }
        stubHistory([managerMessage(id: 10, text: "второе")])
        try await waitUntil("второй страницы") { controller.store.messages.count == 2 }

        let queries = StubURLProtocol.requests(path: messagesPath).map { $0.url.query ?? "" }
        XCTAssertFalse(queries[0].contains("since="), "стартовая история идёт без курсора")
        XCTAssertTrue(
            queries.contains { $0.contains("since=9") },
            "после первой страницы догон обязан нести курсор: \(queries)"
        )
    }

    func testПовторнаяСтраницаНеДублируетСообщение() async throws {
        let controller = try await started()
        stubHistory([managerMessage(id: 9, text: "я тут")])

        try await waitUntil("первого появления") { controller.store.messages.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(controller.store.messages.count, 1)
    }

    /// Оборванная сеть у того, кто просто смотрит переписку, — не повод красить экран.
    func testОшибкаФоновогоДогонаНеПоказываетсяПользователю() async throws {
        let controller = try await started()
        StubURLProtocol.enqueue(path: messagesPath, .json(["error": "boom"], status: 500))

        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(controller.store.connectionError)
    }

    /// Гарантия здесь — «после stop() НОВЫЕ циклы догона не начинаются», а не «сеть замирает
    /// в ту же наносекунду». Запрос, отправленный до stop(), долетает: URLSession стартует
    /// его не мгновенно (стенд считает запросы в `startLoading`), и снятая сразу после stop()
    /// отметка не включала бы его — тест падал примерно раз на шесть прогонов.
    /// Поэтому отметка снимается после паузы, достаточной, чтобы всё уже отправленное
    /// долетело, а проверяется следующий за ней интервал.
    func testStopОстанавливаетДогон() async throws {
        let controller = try await started()
        stubHistory()
        try await Task.sleep(nanoseconds: 150_000_000)

        controller.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        let afterStop = StubURLProtocol.requests(path: messagesPath).count
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(StubURLProtocol.requests(path: messagesPath).count, afterStop)
    }

    /// Экран открыли повторно внутри живого процесса: рукопожатия быть не должно, а лента
    /// обязана догнаться — до 0.2.4 здесь стоял молчаливый выход.
    func testПовторноеОткрытиеЭкранаДогоняетБезВторойРегистрации() async throws {
        let controller = try await started()
        controller.stop()
        let historyBefore = StubURLProtocol.requests(path: messagesPath).count
        stubHistory([managerMessage(id: 11, text: "ответил, пока чат был закрыт")])

        controller.start()

        try await waitUntil("догона после переоткрытия") {
            controller.store.messages.contains { $0.content == "ответил, пока чат был закрыт" }
        }
        XCTAssertEqual(StubURLProtocol.requests(path: registerPath).count, 1)
        XCTAssertGreaterThan(StubURLProtocol.requests(path: messagesPath).count, historyBefore)
    }

    func testВозвратИзФонаПриЗакрытомЭкранеНичегоНеДелает() async throws {
        let controller = try await started()
        controller.stop()
        let afterStop = StubURLProtocol.requests(path: messagesPath).count

        controller.onEnterForeground()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(StubURLProtocol.requests(path: messagesPath).count, afterStop)
    }
}
