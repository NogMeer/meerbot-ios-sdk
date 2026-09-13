// Публичная точка входа: порядок применения identity, выход, смена пользователя, сброс и
// то, что переживает перезапуск приложения. Каждый тест — со своим доменом `UserDefaults`:
// флаг выхода и хэш применённой identity живут на диске, и `.standard` пронёс бы их дальше.

import XCTest
@testable import MeerBotSDK

/// Неподписанный JWT с нужным `sub`: SDK подпись не проверяет, ему нужен только payload.
/// `.sortedKeys` обязателен: порядок ключей `Dictionary` между экземплярами не гарантирован,
/// и два вызова с одними аргументами давали разные строки — тесты сравнивают их на равенство.
func makeIdentityJWT(sub: String, iat: Int = 1) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["sub": sub, "iat": iat], options: .sortedKeys)
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

    /// Номер смены identity этой установки — то, по чему сервер упорядочивает выходы и входы
    /// вместо часов устройства.
    private var identitySeq: Int {
        guard let installationId = defaults.string(forKey: "meerbot.installationId") else { return 0 }
        return IdentityFlagStore(defaults: defaults).identitySeq(installationId: installationId)
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

    /// Сброс отменяет только ПОСЛЕДНЮЮ задачу очереди; остальные ждут предыдущую и об отмене
    /// не знают. Без сверки ревизии они применили бы вход и выход к прежнему клиенту и снова
    /// записали флаг, который сброс только что стёр.
    func testResetПобеждаетНесколькоВызововВОчереди() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a"))
        let first = try XCTUnwrap(sdk.identityTask)
        sdk.identify(token: nil)
        let second = try XCTUnwrap(sdk.identityTask)
        sdk.identify(token: makeIdentityJWT(sub: "user-b"))
        let third = try XCTUnwrap(sdk.identityTask)

        sdk.reset()
        await first.value
        await second.value
        await third.value

        XCTAssertNil(defaults.string(forKey: IdentityFlagStore.pendingLogoutKey))
        XCTAssertNil(defaults.string(forKey: AppliedIdentityStore.key))
    }

    // MARK: Смена пользователя

    /// Подтвердить выход, стоящий после первого входа, — чтобы следующий шаг теста проверял
    /// СВОЙ флаг, а не оставшийся от входа.
    private func confirmPendingLogout(_ sdk: MeerBot) async throws {
        stubRegister(unlinked: true)
        _ = try await register(sdk)
        XCTAssertFalse(logoutPending)
        StubURLProtocol.reset()
    }

    func testДругойПользовательБезВыходаСтавитВыходИЧиститЛентуСразу() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a"))
        await sdk.identityTask?.value
        try await confirmPendingLogout(sdk)
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
        try await confirmPendingLogout(sdk)
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
        // Выход первого входа не подтверждён (регистрации не было) и переживает перезапуск.
        let firstRunFlag = defaults.string(forKey: IdentityFlagStore.pendingLogoutKey)
        XCTAssertNotNil(firstRunFlag)

        let secondRun = makeSDK()
        let store = try XCTUnwrap(secondRun.chatController()).store
        store.appendUserMessage("лента с прошлого запуска")
        secondRun.identify(token: makeIdentityJWT(sub: "user-42", iat: 2))
        await secondRun.identityTask?.value

        XCTAssertEqual(store.messages.map(\.content), ["лента с прошлого запуска"])
        XCTAssertEqual(
            defaults.string(forKey: IdentityFlagStore.pendingLogoutKey),
            firstRunFlag,
            "тот же человек нового выхода не пишет"
        )

        secondRun.identify(token: makeIdentityJWT(sub: "user-7"))
        XCTAssertTrue(store.messages.isEmpty, "другой человек после перезапуска — смена")
        XCTAssertNotEqual(defaults.string(forKey: IdentityFlagStore.pendingLogoutKey), firstRunFlag)
    }

    // MARK: Отвязка без известного прежнего

    /// Установка связана ещё SDK 0.2.8 (хэш он не писал), первым после обновления входит
    /// другой человек, и его токен сервер отклоняет. Без флага связь прежнего осталась бы, и
    /// новый читал бы его тред.
    func testПервыйВходБезСохранённогоХэшаСтавитВыход() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-b"))
        XCTAssertTrue(logoutPending, "флаг на диске до всякого await")
        await sdk.identityTask?.value
        stubRegister(identityStatus: "rejected", unlinked: true)

        let body = try await register(sdk)

        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertEqual(body["identityToken"] as? String, makeIdentityJWT(sub: "user-b"))
    }

    /// `sub` не читается: сервер токен отклонит и связь прежнего не тронет — рвёт её флаг.
    /// Повтор того же токена — не смена (ключ — сам токен).
    func testТокенБезSubПоверхПрежнегоОтвязываетЕго() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a"))
        await sdk.identityTask?.value
        try await confirmPendingLogout(sdk)
        let store = try XCTUnwrap(sdk.chatController()).store
        store.appendUserMessage("переписка user-a")

        sdk.identify(token: "not-a-jwt")

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(logoutPending)
        await sdk.identityTask?.value
        stubRegister(identityStatus: "rejected", unlinked: true)
        let body = try await register(sdk)
        XCTAssertEqual(body["logout"] as? Bool, true)
        XCTAssertFalse(logoutPending)

        store.appendUserMessage("анонимно")
        sdk.identify(token: "not-a-jwt")
        await sdk.identityTask?.value
        XCTAssertFalse(logoutPending, "тот же токен — не смена")
        XCTAssertEqual(store.messages.map(\.content), ["анонимно"])
    }

    // MARK: Черновик

    /// Встроенный чат не закрывается между выходом A и входом B: поле ввода (оно читает
    /// `ChatStore.draft`) не должно показать B текст, набранный A.
    func testВыходИСменаПользователяСтираютЧерновик() async throws {
        let sdk = makeSDK()
        sdk.identify(token: makeIdentityJWT(sub: "user-a"))
        await sdk.identityTask?.value
        let store = try XCTUnwrap(sdk.chatController()).store
        let field = draftBindingOfChatInput(store)

        field.wrappedValue = "черновик user-a"
        sdk.identify(token: nil)
        XCTAssertEqual(field.wrappedValue, "", "выход стирает черновик сразу")

        field.wrappedValue = "черновик анонима"
        sdk.identify(token: makeIdentityJWT(sub: "user-b"))
        XCTAssertEqual(field.wrappedValue, "", "вход другого человека стирает черновик сразу")
        await sdk.identityTask?.value
    }

    // MARK: Номер смены identity

    /// Порядок применяется сервером по номеру, а не по часам: выход и вход разных людей могли
    /// уйти из разных сетей и приехать в обратном порядке. Каждая смена обязана получить номер
    /// больше предыдущего, и растёт он в той же критической секции, что и флаг выхода.
    ///
    /// Проверяется РОСТ, а не точная величина: одну смену помечают и `MeerBot` (он один знает,
    /// кто был применён до перезапуска), и `APIClient` — номер прибавляется дважды, и это
    /// безвредно: сервер сравнивает только «больше сохранённого».
    func testКаждаяСменаПоднимаетНомерАОбновлениеТокенаНет() async throws {
        let sdk = makeSDK()
        XCTAssertEqual(identitySeq, 0, "смен не было")

        sdk.identify(token: makeIdentityJWT(sub: "user-a", iat: 1))
        await sdk.identityTask?.value
        let afterFirstLogin = identitySeq
        XCTAssertGreaterThan(afterFirstLogin, 0, "кто был связан до первого входа, неизвестно — это смена")

        sdk.identify(token: makeIdentityJWT(sub: " user-a ", iat: 2))
        await sdk.identityTask?.value
        XCTAssertEqual(identitySeq, afterFirstLogin, "свежий токен того же человека — не смена")

        sdk.identify(token: nil)
        await sdk.identityTask?.value
        let afterLogout = identitySeq
        XCTAssertGreaterThan(afterLogout, afterFirstLogin, "выход")

        sdk.identify(token: makeIdentityJWT(sub: "user-a", iat: 3))
        await sdk.identityTask?.value
        let afterReLogin = identitySeq
        XCTAssertGreaterThan(afterReLogin, afterLogout, "вход после выхода — всегда новая связь")

        sdk.identify(token: makeIdentityJWT(sub: "user-b"))
        await sdk.identityTask?.value
        XCTAssertGreaterThan(identitySeq, afterReLogin, "другой человек")
    }

    /// Номер относится к СТРОКЕ УСТРОЙСТВА этой установки: на сервере у другой установки свой
    /// счёт, и чужой номер отбросил бы её смены как старые.
    func testНомерПривязанКУстановке() async throws {
        let sdk = makeSDK()
        sdk.identify(token: nil)
        await sdk.identityTask?.value
        XCTAssertGreaterThan(identitySeq, 0)

        let flags = IdentityFlagStore(defaults: defaults)
        XCTAssertEqual(flags.identitySeq(installationId: "00000000-0000-4000-8000-000000000000"), 0)
    }

    /// `reset()` заводит новую установку — на сервере это чистая строка устройства, и старый
    /// номер сделал бы её первые смены «устаревшими».
    func testResetОбнуляетНомер() async throws {
        let sdk = makeSDK()
        sdk.identify(token: nil)
        await sdk.identityTask?.value
        XCTAssertGreaterThan(identitySeq, 0)

        sdk.reset()

        XCTAssertNil(defaults.string(forKey: IdentityFlagStore.identitySeqKey))
        XCTAssertEqual(identitySeq, 0)
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
