// MeerBot iOS SDK — публичная точка входа.
//
// Минимальная интеграция:
//
//     MeerBot.shared.configure(apiKey: "pk_live_…")           // старт приложения
//     MeerBot.shared.chatView()                               // SwiftUI-экран чата
//     MeerBot.shared.identify(token: jwtОтВашегоБэкенда)      // после входа пользователя
//     MeerBot.shared.setPushToken(deviceToken)                // AppDelegate, если нужны пуши
//
// Полный пример — README.md.

import Foundation
import SwiftUI

public enum MeerBotPlatform {
    public static let version = "0.2.9"
    public static let apiBaseUrl = "https://meerbot.ru"
}

/// Публичный API. Контракт совпадает с Android и RN (docs/mobile-sdk/api-reference.md).
@MainActor
public final class MeerBot {

    public static let shared = MeerBot()

    /// Хранилище идентификаторов, флага выхода и применённой identity. `.standard` у
    /// синглтона; тестам — свой домен, чтобы прогон не оставлял следов.
    private let defaults: UserDefaults
    private(set) var client: APIClient?
    private var controller: ChatController?
    private var configuration: MeerBotConfiguration?
    private var visitorUuid: String?
    /// identity-токен, переданный до configure() — применим, как только появится клиент.
    /// Выход (`nil`) сюда не кладётся: он пишется флагом на диск и доходит сам.
    private var pendingIdentityToken: String?
    /// Последнее применение identity. Следующее ждёт его: см. `identify(token:)`.
    private(set) var identityTask: Task<Void, Never>?
    /// Растёт в `reset()`. Применение identity, поставленное в очередь до сброса, сверяет его
    /// после ожидания предыдущего: `Task.cancel()` само по себе ничего не останавливает, и
    /// выход в очереди снова записал бы флаг, только что стёртый сбросом.
    private var stateRevision = 0

    /// APNs-токен устройства, если хост его получил.
    ///
    /// Платформа пуши НЕ отправляет (решение владельца): «менеджер ответил» уходит вебхуком
    /// на бэкенд интегратора, а адресует он по своему `external_user_id`. Токен здесь —
    /// чтобы приложению было откуда его взять и отдать своему бэкенду; в MeerBot он не
    /// уходит. См. `deviceToken` в шапке `APIClient`.
    public private(set) var pushToken: String?

    private convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Настроить SDK.
    ///
    /// - Parameters:
    ///   - apiKey: `pk_live_*` мобильного приложения (кабинет → Бот → Каналы → Мобильные
    ///     приложения). Один ключ на чат, историю и регистрацию; разрешённые домены и
    ///     заголовок `Origin` каналу не нужны.
    ///   - baseURL: адрес платформы (для стенда).
    public func configure(
        apiKey: String,
        baseURL: URL = URL(string: MeerBotPlatform.apiBaseUrl)!
    ) {
        configure(MeerBotConfiguration(apiKey: apiKey, baseURL: baseURL))
    }

    /// Настройка целиком объектом конфигурации (используется тестами и хост-приложениями,
    /// которым нужен свой `URLSessionConfiguration`).
    public func configure(
        _ configuration: MeerBotConfiguration,
        sessionConfiguration: URLSessionConfiguration = APIClient.defaultSessionConfiguration()
    ) {
        let visitorUuid = getOrCreateUuid(forKey: Self.visitorUuidKey)
        let client = APIClient(
            config: configuration,
            visitorUuid: visitorUuid,
            installationId: getOrCreateInstallationId(),
            sessionConfiguration: sessionConfiguration,
            flagStore: IdentityFlagStore(defaults: defaults)
        )

        self.configuration = configuration
        self.visitorUuid = visitorUuid
        let controller = ChatController(client: client)
        self.client = client
        self.controller = controller

        // Регистрация здесь СОЗНАТЕЛЬНО не делается: она заводит строку `MobileDevice`, и
        // вызов на старте приложения записал бы «устройство» каждому, кто чат ни разу не
        // открыл. Сессия открывается при первом показе экрана; кому нужен прогрев —
        // preconnect().

        // Смена, пришедшая до configure(), уже записана на диск (`recordIdentity`): флаг выхода
        // лежит, лента нового контроллера пуста. Клиенту остаётся только получить токен.
        if let token = pendingIdentityToken {
            pendingIdentityToken = nil
            enqueueIdentity(
                token,
                change: .subject(unlinkPrevious: false),
                client: client,
                controller: controller,
                resetsFeed: false
            )
        }
    }

    /// Связать чат с пользователем вашей системы.
    ///
    /// `token` — HS256-JWT, подписанный ВАШИМ бэкендом секретом этого приложения
    /// (кабинет → Мобильные приложения → секрет для identity-токена; не путать с секретом
    /// вебхука). Claims: `sub` — ваш id
    /// пользователя, `iat`/`exp`, опционально `email`/`name`. Токен обязан быть СВЕЖИМ —
    /// сервер устанавливает связь только по выпущенным не ранее пяти минут назад.
    ///
    /// Claim `vid` (привязка к `visitorUuid` устройства) сервер проверяет, только если он в
    /// токене есть. Класть его пока НЕ НАДО: `visitorUuid` наружу не отдаётся, и подставить
    /// туда нечего — значение «на глазок» даст `rejected`.
    ///
    /// Токен применяется НЕМЕДЛЕННО: текущая сессия сбрасывается, и следующий запрос
    /// перерегистрирует устройство уже с идентичностью. Результат проверки — в
    /// `identityStatus`; провал SOFT: чат продолжает работать анонимно. Если токен принадлежит
    /// ДРУГОМУ пользователю (другой `sub`), лента на экране очищается, а следующая регистрация
    /// отвязывает устройство от прежнего — как при выходе, даже если токен нового сервер не
    /// примет. Свежий токен того же пользователя ленту не трогает, в том числе после
    /// перезапуска приложения (кто был применён, SDK помнит в виде хэша).
    ///
    /// `identify(token: nil)` — настоящий выход: с 0.2.9 SDK при следующем подключении
    /// отвязывает устройство на сервере (прежний тред остаётся за прежним пользователем,
    /// новый начинается пустым) и сразу очищает ленту на экране. Сигнал сохраняется на диск
    /// и переживает перезапуск приложения, вызов до `configure(...)` тоже работает.
    /// Вызывайте `nil` ТОЛЬКО на реальный выход, а не когда токен просто не успели получить:
    /// каждый такой вызов разрывает связь пользователя с его перепиской.
    public func identify(token: String?) {
        // Решение и флаг — ПЕРВЫМИ и на диск: регистрация ленивая, и выход (или смена
        // человека) до configure() либо перед убийством приложения иначе потерялись бы.
        let change = recordIdentity(token)

        guard let client, let controller else {
            pendingIdentityToken = token
            return
        }

        // Ленту чистим, только когда сменился ЧЕЛОВЕК. Токены живут минуты, и хост выпускает
        // свежий на каждый вход в чат: сравнение строк сбрасывало бы ленту (и обрывало
        // стримящийся ответ) на каждом таком вызове. Выход чистит всегда: связь могла
        // остаться с прошлого запуска.
        enqueueIdentity(
            token,
            change: change,
            client: client,
            controller: controller,
            resetsFeed: change != .refresh
        )
    }

    /// Сравнить с тем, кто применён последним (между запусками — по хэшу на диске), и
    /// записать новое состояние: кто применён и нужен ли выход.
    private func recordIdentity(_ token: String?) -> IdentityChange {
        let installationId = getOrCreateInstallationId()
        let applied = AppliedIdentityStore(defaults: defaults)
        let flags = IdentityFlagStore(defaults: defaults)
        let previous = applied.current

        guard let token else {
            flags.markLogout(installationId: installationId)
            applied.current = nil
            return .logout
        }

        let subject = Self.identitySubject(of: token)
        let digest = applied.digest(subject: subject ?? token, installationId: installationId)
        if digest == previous { return .refresh }
        applied.current = digest
        // Рвём связь прежнего, только если и новый токен несёт `sub`. Токен без `sub` сервер
        // отклоняет и связи по нему не ставит; флаг же на КАЖДЫЙ такой вызов (у них нет
        // устойчивого ключа, и каждый выглядит сменой) уводил бы строку устройства в отставку
        // и начинал новый тред раз за разом.
        let unlinkPrevious = previous != nil && subject != nil
        if unlinkPrevious { flags.markLogout(installationId: installationId) }
        return .subject(unlinkPrevious: unlinkPrevious)
    }

    /// Вызовы применяются строго по очереди: `identify(nil)` и следом `identify(token: B)`,
    /// исполненные в обратном порядке, оставили бы пользователя B анонимным.
    private func enqueueIdentity(
        _ token: String?,
        change: IdentityChange,
        client: APIClient,
        controller: ChatController,
        resetsFeed: Bool
    ) {
        // Лента чистится СРАЗУ, а контроллер до применения не ходит в сеть: сообщение,
        // набранное в это окно, иначе ушло бы с прежней identity или стёрлось бы сбросом.
        if resetsFeed { controller.beginIdentityChange() }
        let previous = identityTask
        let revision = stateRevision
        identityTask = Task {
            await previous?.value
            guard self.stateRevision == revision, !Task.isCancelled else { return }
            await client.applyIdentity(token, change: change)
            if resetsFeed { controller.finishIdentityChange() }
        }
    }

    /// Что сервер сделал с последним `identityToken`. `nil` — регистрации ещё не было.
    public func identityStatus() async -> IdentityStatus? {
        guard let client else { return nil }
        return await client.identityStatus
    }

    /// SwiftUI-экран чата. Возвращает готовый View — прикрепляйте к своей иерархии
    /// (`sheet`, `fullScreenCover`, `NavigationLink` или прямо в `body`).
    ///
    /// До `configure(...)` возвращает экран с явным сообщением об ошибке, а не пустоту.
    public func chatView(
        title: String = "Поддержка",
        primaryColor: Color = .blue,
        onClose: (() -> Void)? = nil,
        // false — хост показывает чат вкладкой и рисует заголовок сам.
        showHeader: Bool = true
    ) -> some View {
        Group {
            if let controller {
                ChatView(
                    controller: controller,
                    title: title,
                    primaryColor: primaryColor,
                    onClose: onClose,
                    showHeader: showHeader
                )
            } else {
                NotConfiguredView()
            }
        }
    }

    /// Контроллер чата — для приложений, которые рисуют свой UI поверх нашего состояния.
    public func chatController() -> ChatController? { controller }

    /// Открыть сессию заранее (например, когда пользователь навёлся на кнопку поддержки),
    /// чтобы первый экран чата открылся без сетевой паузы. Побочный эффект — визитор
    /// появится в аналитике владельца, даже если чат так и не откроют.
    public func preconnect() { controller?.start() }

    /// Сохранить APNs-токен (из `didRegisterForRemoteNotificationsWithDeviceToken`).
    ///
    /// ⚠️ В MeerBot он НЕ отправляется. Пуш «менеджер ответил» шлёт ваш бэкенд — платформа
    /// уведомляет его вебхуком и адресует по `external_user_id` из identity-токена. Метод
    /// существует, чтобы токен лежал в одном известном месте (`MeerBot.shared.pushToken`)
    /// и вы отдали его своему серверу.
    ///
    /// Почему не шлём: `deviceToken` на нашей стороне — ключ уникальности устройства, от
    /// которого зависит тред диалога. Отправь мы туда APNs-токен, его ротация или
    /// восстановление из бэкапа заводили бы пользователю новый диалог с пустой историей.
    public func setPushToken(_ deviceToken: Data) {
        pushToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// Привести ленту к серверной: приложение вернулось на передний план или его бэкенд
    /// разбудил его пушем «менеджер ответил».
    ///
    /// Паритет с Android (`MeerBot.refresh()`). Отличие от `handlePush(_:)`: тот переключает
    /// тред по `conversationId` из полезной нагрузки, а этот перечитывает текущий — то есть
    /// работает и тогда, когда пуш пришёл без id (у канала он не обязателен: тред один на
    /// устройство).
    public func refresh() {
        controller?.refresh()
    }

    /// Обработать входящий пуш. Возвращает `true`, если пуш наш и обработан.
    /// Полезная нагрузка: `{"conversationId": 123}` (число или строка).
    @discardableResult
    public func handlePush(_ payload: [AnyHashable: Any]) -> Bool {
        let raw = payload["conversationId"]
        let conversationId = (raw as? Int) ?? (raw as? String).flatMap(Int.init)
        guard let conversationId else { return false }
        controller?.openConversation(id: conversationId)
        return true
    }

    /// Сбросить состояние SDK (GDPR Art. 17 на стороне клиента): идентификатор установки,
    /// визитор, история, токены, неотправленный сигнал выхода.
    ///
    /// ⚠️ Новый идентификатор установки означает НОВЫЙ тред: прежняя переписка остаётся на
    /// сервере за прежним устройством и в приложении больше не появится. Серверного
    /// эндпоинта стирания у мобильного канала пока нет — удаление данных заказывается
    /// владельцу проекта.
    public func reset() {
        controller?.stop()
        controller?.store.resetForLogout()
        // Сначала ревизия: задачи в очереди сверяют её и не применяют выход к прежнему клиенту.
        stateRevision += 1
        identityTask?.cancel()
        identityTask = nil
        client = nil
        controller = nil
        configuration = nil
        visitorUuid = nil
        pendingIdentityToken = nil
        pushToken = nil
        defaults.removeObject(forKey: Self.visitorUuidKey)
        defaults.removeObject(forKey: Self.installationIdKey)
        // Выход относился к прежней установке; новая с сервером ещё не связана. Если
        // применение, уже вошедшее в клиент, допишет флаг после этой строки, — он помечен
        // прежней установкой, и новая его сотрёт, не отправив.
        IdentityFlagStore(defaults: defaults).clearAll()
        AppliedIdentityStore(defaults: defaults).current = nil
    }

    // MARK: - Внутреннее

    private static let visitorUuidKey = "meerbot.visitorUuid"
    private static let installationIdKey = "meerbot.installationId"

    /// Идентификатор установки — то, что уходит в `deviceToken` регистрации и через
    /// `MobileDevice.id` определяет тред. Отдельный ключ от `visitorUuid`: у них разные
    /// роли на сервере (один — колонка визитора, второй — ключ уникальности устройства), и
    /// склеенные они однажды разъедутся молча.
    private func getOrCreateInstallationId() -> String {
        getOrCreateUuid(forKey: Self.installationIdKey)
    }

    /// `sub` identity-токена — только чтобы понять, сменился ли человек. Подпись здесь не
    /// проверяется и не должна: связь устанавливает сервер, а по этому значению решается
    /// лишь, чистить ли ленту. `nil` — токен не JWT или `sub` в нём нет.
    ///
    /// Пробелы по краям обрезаются, как на сервере (`identity-token.ts`): иначе `" u1"` и
    /// `"u1"` — один человек для сервера — выглядели бы здесь сменой и рвали его связь.
    nonisolated static func identitySubject(of token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard
            let data = Data(base64Encoded: base64),
            let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawSubject = claims["sub"] as? String
        else { return nil }
        let subject = rawSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? nil : subject
    }

    private func getOrCreateUuid(forKey key: String) -> String {
        if let stored = defaults.string(forKey: key), stored.count == 36 {
            return stored
        }
        let new = UUID().uuidString.lowercased()
        defaults.set(new, forKey: key)
        return new
    }
}

/// Экран для случая «SDK не настроен» — вместо молчаливой пустоты.
struct NotConfiguredView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("MeerBot не настроен")
                .font(.headline)
            Text("Вызовите MeerBot.shared.configure(apiKey:) при старте приложения.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mbSurface)
    }
}
