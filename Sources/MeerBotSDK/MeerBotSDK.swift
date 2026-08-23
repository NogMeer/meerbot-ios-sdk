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
    public static let version = "0.2.1"
    public static let apiBaseUrl = "https://meerbot.ru"
}

/// Публичный API. Контракт совпадает с Android и RN (docs/mobile-sdk/api-reference.md).
@MainActor
public final class MeerBot {

    public static let shared = MeerBot()

    private var client: APIClient?
    private var controller: ChatController?
    private var configuration: MeerBotConfiguration?
    private var visitorUuid: String?
    /// identity-токен, переданный до configure() — применим, как только появится клиент.
    private var pendingIdentityToken: String?

    /// APNs-токен устройства, если хост его получил.
    ///
    /// Платформа пуши НЕ отправляет (решение владельца): «менеджер ответил» уходит вебхуком
    /// на бэкенд интегратора, а адресует он по своему `external_user_id`. Токен здесь —
    /// чтобы приложению было откуда его взять и отдать своему бэкенду; в MeerBot он не
    /// уходит. См. `deviceToken` в шапке `APIClient`.
    public private(set) var pushToken: String?

    private init() {}

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
        let visitorUuid = Self.getOrCreateVisitorUuid()
        let client = APIClient(
            config: configuration,
            visitorUuid: visitorUuid,
            installationId: Self.getOrCreateInstallationId(),
            sessionConfiguration: sessionConfiguration
        )

        self.configuration = configuration
        self.visitorUuid = visitorUuid
        self.client = client
        self.controller = ChatController(client: client)

        // Регистрация здесь СОЗНАТЕЛЬНО не делается: она заводит строку `MobileDevice`, и
        // вызов на старте приложения записал бы «устройство» каждому, кто чат ни разу не
        // открыл. Сессия открывается при первом показе экрана; кому нужен прогрев —
        // preconnect().

        if let token = pendingIdentityToken {
            pendingIdentityToken = nil
            identify(token: token)
        }
    }

    /// Связать чат с пользователем вашей системы.
    ///
    /// `token` — HS256-JWT, подписанный ВАШИМ бэкендом секретом этого приложения
    /// (кабинет → Мобильные приложения → секрет подписи). Claims: `sub` — ваш id
    /// пользователя, опционально `email`/`name`, обязательный `vid` = `visitorUuid`
    /// устройства, и токен должен быть свежим (сервер принимает выпущенные не ранее пяти
    /// минут назад).
    ///
    /// Токен применяется НЕМЕДЛЕННО: текущая сессия сбрасывается, и следующий запрос
    /// перерегистрирует устройство уже с идентичностью. Результат проверки — в
    /// `identityStatus`; провал SOFT: чат продолжает работать анонимно.
    ///
    /// `identify(token: nil)` — выход пользователя: связь на сервере НЕ стирается (она
    /// принадлежит прежнему владельцу устройства), но новая сессия будет анонимной.
    public func identify(token: String?) {
        guard let client else {
            pendingIdentityToken = token
            return
        }
        Task {
            await client.setIdentityToken(token)
            await client.invalidateToken()
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
        onClose: (() -> Void)? = nil
    ) -> some View {
        Group {
            if let controller {
                ChatView(
                    controller: controller,
                    title: title,
                    primaryColor: primaryColor,
                    onClose: onClose
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
    /// визитор, история, токены.
    ///
    /// ⚠️ Новый идентификатор установки означает НОВЫЙ тред: прежняя переписка остаётся на
    /// сервере за прежним устройством и в приложении больше не появится. Серверного
    /// эндпоинта стирания у мобильного канала пока нет — удаление данных заказывается
    /// владельцу проекта.
    public func reset() {
        controller?.stop()
        controller?.store.resetForLogout()
        client = nil
        controller = nil
        configuration = nil
        visitorUuid = nil
        pendingIdentityToken = nil
        pushToken = nil
        UserDefaults.standard.removeObject(forKey: Self.visitorUuidKey)
        UserDefaults.standard.removeObject(forKey: Self.installationIdKey)
    }

    // MARK: - Внутреннее

    private static let visitorUuidKey = "meerbot.visitorUuid"
    private static let installationIdKey = "meerbot.installationId"

    private static func getOrCreateVisitorUuid() -> String {
        getOrCreateUuid(forKey: visitorUuidKey)
    }

    /// Идентификатор установки — то, что уходит в `deviceToken` регистрации и через
    /// `MobileDevice.id` определяет тред. Отдельный ключ от `visitorUuid`: у них разные
    /// роли на сервере (один — колонка визитора, второй — ключ уникальности устройства), и
    /// склеенные они однажды разъедутся молча.
    private static func getOrCreateInstallationId() -> String {
        getOrCreateUuid(forKey: installationIdKey)
    }

    private static func getOrCreateUuid(forKey key: String) -> String {
        if let stored = UserDefaults.standard.string(forKey: key), stored.count == 36 {
            return stored
        }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: key)
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
