// Публичная точка входа: порядок применения identity, выход, смена пользователя, сброс и
// то, что переживает перезапуск приложения. Каждый тест — со своим доменом `UserDefaults`:
// флаг выхода и хэш применённой identity живут на диске, и `.standard` пронёс бы их дальше.

import XCTest
@testable import MeerBotSDK

/// Неподписанный JWT с нужным `sub`: SDK подпись не проверяет, ему нужен только payload.
func makeIdentityJWT(sub: String, iat: Int = 1) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["sub": sub, "iat": iat])
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJIUzI1NiJ9.\(encoded).signature"
}

@MainActor
final class MeerBotTests: XCTestCase {

    private let registerPath = "/api/v1/mobile/register"

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        suiteName = "MeerBotSDKTests.MeerBot.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSDK(configured: Bool = true) -> MeerBot {
        let sdk = MeerBot(defaults: defaults)
        if configured { configure(sdk) }
        return sdk
    }

    private func configure(_ sdk: MeerBot) {
        sdk.configure(
            MeerBotConfiguration(apiKey: "pk_live_test", baseURL: URL(string: "https://meerbot.test")!),
            sessionConfiguration: .stubbed()
        )
    }

    private var logoutPending: Bool {
        guard let installationId = defaults.string(forKey: "meerbot.installationId") else { return false }
        return IdentityFlagStore(defaults: defaults).pendingLogout(installationId: installationId) != nil
    }

    private func stubRegister(identityStatus: String = "verified", unlinked: Bool? = nil) {
        var identity: [String: Any] = ["status": identityStatus]
        if let unlinked { identity["unlinked"] = unlinked }
        StubURLProtocol.enqueue(
            path: registerPath,
            .json(["deviceId": "42", "jwt": "jwt-1", "expiresIn": 900, "identity": identity])
        )
    }

    private func register(_ sdk: MeerBot) async throws -> [String: Any] {
        let client = try XCTUnwrap(sdk.client)
        _ = try await client.openSession()
        return try XCTUnwrap(StubURLProtocol.requests(path: registerPath).last?.body)
    }

    // MARK: Порядок

    /// `identify(nil)` и следом `identify(B)`, применённые в обратном порядке, оставили бы
    /// B анонимным, а выход — неотправленным.
    func testВыходИВходДругогоПрименяютсяПоПорядку() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a"))
        sdk.identify(token: nil)
        sdk.identify(token: makeIdentityJWT(sub: "user-b"))
        await sdk.identityTask?.value
        stubRegister(unlinked: true)

        let body = try await register(sdk)

        XCTAssertEqual(body["identityToken"] as? String, makeIdentityJWT(sub: "user-b"))
        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertFalse(logoutPending, "сервер подтвердил выход")
    }

    func testВыходДоConfigureДоходитДоПервойРегистрации() async throws {
        let sdk = makeSDK(configured: false)
        sdk.identify(token: nil)
        configure(sdk)
        stubRegister(identityStatus: "not_provided", unlinked: true)

        let body = try await register(sdk)

        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertNil(body["identityToken"])
        XCTAssertFalse(logoutPending)
    }

    // MARK: Сброс

    /// `Task.cancel()` ничего не останавливает сам: выход, стоявший в очереди, после сброса
    /// снова записал бы флаг, и новая установка начала бы с чужого выхода.
    func testResetСнимаетФлагИОтменяетВыходВОчереди() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a"))
        sdk.identify(token: nil)
        XCTAssertTrue(logoutPending, "выход записан синхронно")
        let queued = try XCTUnwrap(sdk.identityTask)

        sdk.reset()
        await queued.value

        XCTAssertNil(defaults.string(forKey: IdentityFlagStore.pendingLogoutKey))
        XCTAssertNil(defaults.string(forKey: AppliedIdentityStore.key))
        XCTAssertNil(sdk.client)
    }

    // MARK: Смена пользователя

    func testДругойПользовательБезВыходаСтавитВыходИЧиститЛентуСразу() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a"))
        await sdk.identityTask?.value
        XCTAssertFalse(logoutPending, "первый вход — рвать нечего")
        let store = try XCTUnwrap(sdk.chatController()).store
        store.appendUserMessage("переписка user-a")

        sdk.identify(token: makeIdentityJWT(sub: "user-b"))

        XCTAssertTrue(store.messages.isEmpty, "лента прежнего стирается до всякого await")
        XCTAssertTrue(logoutPending, "флаг на диске сразу — переживёт убийство приложения")
        await sdk.identityTask?.value
        // Токен нового сервер не принял (`stale`) — связь прежнего всё равно рвётся.
        stubRegister(identityStatus: "stale", unlinked: true)
        let body = try await register(sdk)
        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertEqual(body["identityToken"] as? String, makeIdentityJWT(sub: "user-b"))
    }

    /// Токены живут минуты, хост выпускает свежий на каждый вход в чат. `sub` сравнивается
    /// после обрезки пробелов — как на сервере.
    func testСвежийТокенТогоЖеПользователяНеСтавитВыходИНеЧиститЛенту() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a", iat: 1))
        await sdk.identityTask?.value
        let store = try XCTUnwrap(sdk.chatController()).store
        store.appendUserMessage("моё сообщение")

        sdk.identify(token: makeIdentityJWT(sub: " user-a ", iat: 2))
        await sdk.identityTask?.value

        XCTAssertEqual(store.messages.map(\.content), ["моё сообщение"])
        XCTAssertFalse(logoutPending)
        stubRegister()
        let body = try await register(sdk)
        XCTAssertNil(body["logout"])
        XCTAssertEqual(body["identityToken"] as? String, makeIdentityJWT(sub: " user-a ", iat: 2))
    }

    // MARK: Холодный старт

    /// Новый процесс: память пуста, а человек тот же. Раньше первый `identify` после запуска
    /// считался сменой — чистил ленту и обрывал ответ на каждом холодном старте.
    func testПослеПерезапускаТотЖеПользовательНеСчитаетсяСменой() async throws {
        let firstRun = makeSDK()
        firstRun.identify(token: makeIdentityJWT(sub: "user-42", iat: 1))
        await firstRun.identityTask?.value
        let stored = try XCTUnwrap(defaults.string(forKey: AppliedIdentityStore.key))
        XCTAssertFalse(stored.contains("user-42"), "id пользователя не лежит открытым текстом")

        let secondRun = makeSDK()
        let store = try XCTUnwrap(secondRun.chatController()).store
        store.appendUserMessage("лента с прошлого запуска")
        secondRun.identify(token: makeIdentityJWT(sub: "user-42", iat: 2))
        await secondRun.identityTask?.value

        XCTAssertEqual(store.messages.map(\.content), ["лента с прошлого запуска"])
        XCTAssertFalse(logoutPending)

        secondRun.identify(token: makeIdentityJWT(sub: "user-7"))
        XCTAssertTrue(store.messages.isEmpty, "другой человек после перезапуска — смена")
        XCTAssertTrue(logoutPending)
    }

    /// Выход забывает, кто был: вход того же человека после выхода — новая связь.
    func testВыходЗабываетПрименённогоПользователя() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-42"))
        await sdk.identityTask?.value

        sdk.identify(token: nil)
        await sdk.identityTask?.value

        XCTAssertNil(defaults.string(forKey: AppliedIdentityStore.key))
    }
}
