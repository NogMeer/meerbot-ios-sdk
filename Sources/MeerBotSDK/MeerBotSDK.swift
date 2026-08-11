// MeerBot iOS SDK — публичная точка входа.
//
// Минимальная интеграция:
//
//     MeerBot.shared.configure(apiKey: "pk_live_…")           // старт приложения
//     MeerBot.shared.chatView()                               // SwiftUI-экран чата
//     MeerBot.shared.setPushToken(deviceToken)                // AppDelegate, если нужны пуши
//
// Полный пример и требования к ключам — README.md.

import Foundation
import SwiftUI

public enum MeerBotPlatform {
    public static let version = "0.1.0"
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
    /// APNs-токен, полученный до configure() — зарегистрируем, как только появится конфигурация.
    private var pendingApnsToken: String?

    private init() {}

    /// Настроить SDK.
    ///
    /// - Parameters:
    ///   - apiKey: `pk_live_*` headless-виджета из кабинета — транспорт чата. Строка `origin`
    ///     (по умолчанию `https://<bundleId>`) обязана быть в списке разрешённых доменов
    ///     этого ключа, иначе handshake вернёт `key_invalid`.
    ///   - pushApiKey: `pk_live_*` мобильного приложения — нужен ТОЛЬКО для APNs. Сегодня это
    ///     отдельный ключ: JWT из `/mobile/register` не принимается чат-эндпоинтом (см. README,
    ///     «Два ключа»). Без пушей параметр не нужен.
    ///   - origin: переопределение заголовка `Origin`.
    ///   - baseURL: адрес платформы (для стенда).
    public func configure(
        apiKey: String,
        pushApiKey: String? = nil,
        origin: String? = nil,
        baseURL: URL = URL(string: MeerBotPlatform.apiBaseUrl)!
    ) {
        let configuration = MeerBotConfiguration(
            apiKey: apiKey,
            pushApiKey: pushApiKey,
            baseURL: baseURL,
            origin: origin
        )
        configure(configuration)
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
            sessionConfiguration: sessionConfiguration
        )

        self.configuration = configuration
        self.visitorUuid = visitorUuid
        self.client = client
        self.controller = ChatController(client: client)

        // Handshake здесь СОЗНАТЕЛЬНО не делаем: `/widget/session` заводит строку
        // WidgetVisitor, и рукопожатие на старте приложения записало бы «посетителя»
        // каждому, кто чат ни разу не открыл, — это перекосило бы аналитику владельца.
        // Сессия открывается при первом показе экрана; кому нужен прогрев — preconnect().

        if let token = pendingApnsToken {
            pendingApnsToken = nil
            setPushToken(hex: token)
        }
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

    /// Зарегистрировать APNs-токен (из `didRegisterForRemoteNotificationsWithDeviceToken`).
    /// Требует `pushApiKey` в `configure`; без него вызов игнорируется с записью в лог.
    public func setPushToken(_ deviceToken: Data) {
        setPushToken(hex: deviceToken.map { String(format: "%02x", $0) }.joined())
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

    /// Сбросить состояние SDK (GDPR Art. 17 на стороне клиента): визитор, история, токены.
    /// Серверные данные удаляет `POST /api/v1/widget/visitor/forget` — отдельный вызов.
    public func reset() {
        controller?.stop()
        controller?.store.resetForLogout()
        client = nil
        controller = nil
        configuration = nil
        visitorUuid = nil
        pendingApnsToken = nil
        UserDefaults.standard.removeObject(forKey: Self.visitorUuidKey)
    }

    // MARK: - Внутреннее

    private func setPushToken(hex: String) {
        guard let client, let configuration else {
            // configure() ещё не вызван — запомним и зарегистрируем после.
            pendingApnsToken = hex
            return
        }
        guard configuration.pushApiKey?.isEmpty == false else {
            print("[MeerBot] setPushToken проигнорирован: не задан pushApiKey в configure(...)")
            return
        }
        Task {
            do {
                _ = try await client.registerDevice(apnsToken: hex)
            } catch {
                // Пуши — не критичный путь: чат работает и без них. Молча не глотаем.
                print("[MeerBot] регистрация APNs-токена не удалась: \(error.localizedDescription)")
            }
        }
    }

    private static let visitorUuidKey = "meerbot.visitorUuid"

    private static func getOrCreateVisitorUuid() -> String {
        if let stored = UserDefaults.standard.string(forKey: visitorUuidKey), stored.count == 36 {
            return stored
        }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: visitorUuidKey)
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
