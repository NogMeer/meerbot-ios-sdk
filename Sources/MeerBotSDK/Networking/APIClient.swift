// MeerBot iOS SDK — HTTP-клиент платформы.
//
// ── Контракт канала `mobile_app` (сверено по коду agentbot-platform на 2026-08-15) ──────
//
// ОДИН ключ `pk_live_*` мобильного приложения и три эндпоинта СВОЕГО канала:
//   POST /api/v1/mobile/register     — регистрация устройства → JWT (claim `ch=mobile_app`)
//   POST /api/v1/mobile/chat/stream  — SSE-поток ответа (тело: {message})
//   GET  /api/v1/mobile/messages     — догон истории (?since&limit)
//
// ── Что изменилось против 0.1.x и почему ────────────────────────────────────────────────
//
//   • Ушли ДВА ключа. 0.1.x возил чат по ключу headless-виджета (`/api/v1/widget/*`), потому
//     что чата в мобильном канале не существовало. Теперь он есть, и JWT из `/mobile/register`
//     принимается им напрямую: канал заявлен claim'ом `ch`, а не подразумевается совпадением
//     чисел в `aud`.
//   • Ушёл `Origin`. Виджетный handshake пинует ключ по домену, и приложению приходилось
//     вписывать `https://<bundleId>` в разрешённые домены кабинета. Мобильные роуты Origin не
//     проверяют вовсе (`verifyWidgetJwt` зовётся без `expect.origin`) — заголовок больше не
//     шлётся и в конфигурации его нет.
//   • Ушёл `conversationId` из тела запроса. Диалог резолвит СЕРВЕР по паре (приложение,
//     устройство) — тот же ключ, что строит `mobileExternalRef`. Клиент его больше не
//     выбирает; наружу id приходит событием `meta` и нужен только чтобы подавить свой же пуш.
//
// ── `deviceToken` — это идентификатор устройства, а не адрес пуша ───────────────────────
//
// Поле обязательное и служит ключом уникальности `(приложение, deviceToken)`, то есть от него
// зависит `MobileDevice.id`, а от него — ТРЕД диалога. Пуши платформа не отправляет вовсе
// (решение владельца; единственный читатель поля — мёртвый `server/lib/mobile/push-service.ts`,
// адресация наружу идёт по `external_user_id` в вебхуке интегратору). Поэтому SDK шлёт сюда
// СТАБИЛЬНЫЙ идентификатор установки, а не APNs-токен:
//   • APNs-токен появляется только после разрешения на уведомления — иначе чат был бы
//     недоступен всем, кто его не дал, включая первый запуск до запроса разрешения;
//   • APNs-токен меняется (переустановка, восстановление из бэкапа, ротация Apple) — смена
//     значения завела бы НОВУЮ строку устройства, то есть новый тред с пустой историей.
// Реальный APNs-токен остаётся у хост-приложения (`MeerBot.shared.pushToken`) и уходит на
// бэкенд интегратора, который и шлёт пуш.

import CryptoKit
import Foundation

// MARK: - Конфигурация

public struct MeerBotConfiguration {
    /// `pk_live_*` мобильного приложения (кабинет → Бот → Каналы → Мобильные приложения).
    /// Ключ публичен по замыслу — он зашит в бинарник; всё, что стоит между ним и платным
    /// вызовом модели, — серверные лимиты и допуск.
    public let apiKey: String
    public let baseURL: URL
    public let sdkVersion: String

    public init(
        apiKey: String,
        baseURL: URL = URL(string: MeerBotPlatform.apiBaseUrl)!,
        sdkVersion: String = MeerBotPlatform.version
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.sdkVersion = sdkVersion
    }
}

// MARK: - Ошибки

public enum MeerBotError: Error, LocalizedError {
    /// `configure(...)` не вызван (или вызван с пустым ключом).
    case notConfigured
    /// Сервер ответил кодом ≥400. `code` — машинный код платформы (`key_invalid`,
    /// `rate_limited`, `identity_required`, `jwt_expired`, …).
    case http(status: Int, code: String, message: String)
    /// Транспортная ошибка: нет сети, обрыв соединения, таймаут.
    case network(code: URLError.Code, message: String)
    /// Ошибка внутри уже открытого потока (`event: error`).
    case stream(code: String, message: String)
    case invalidResponse
    case cancelled

    /// Машинный код — для аналитики и тестов.
    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case let .http(_, code, _): return code
        case let .network(code, _): return "network_\(code.rawValue)"
        case let .stream(code, _): return code
        case .invalidResponse: return "invalid_response"
        case .cancelled: return "cancelled"
        }
    }

    /// Текст для пользователя (русский) — то, что показывает ChatView.
    ///
    /// Коды перечислены по РЕАЛЬНЫМ отказам мобильных роутов (`_lib/context.ts`,
    /// `mobile/admission.ts`, `chat/stream/route.ts`), а не по виджетным: они разошлись, и
    /// незнакомый код давал бы бесполезное «Сервер недоступен» на понятной причине.
    public var userMessage: String {
        switch self {
        case .notConfigured:
            return "Чат не настроен. Вызовите MeerBot.shared.configure(apiKey:)."
        case let .http(status, code, _):
            switch code {
            case "key_invalid", "key_revoked":
                return "Неверный или отозванный ключ приложения."
            case "mobile_app_inactive", "instance_disabled", "instance_not_found":
                return "Канал отключён в кабинете."
            case "assistant_disabled":
                return "Ассистент отключён в кабинете."
            case "platform_mismatch":
                return "Ключ выдан для другой платформы."
            case "identity_required":
                return "Приложение требует входа. Войдите и повторите."
            case "daily_budget_exceeded", "insufficient_balance", "wallet_unavailable":
                return "Чат временно недоступен: исчерпан лимит расходов."
            case "conversation_cap_reached":
                return "Достигнут месячный лимит новых обращений."
            case "rate_limited":
                return "Слишком много сообщений. Попробуйте через минуту."
            case "message_too_long":
                return "Сообщение слишком длинное."
            case "channel_mismatch", "device_claim_missing", "device_not_found":
                // Токен от другого канала/устройства либо устройство снято с регистрации
                // (например, выходом пользователя). `device_*` клиент переживает сам —
                // перерегистрацией и одним повтором; до экрана они доходят, только если
                // не помог и повтор. Поэтому «Переподключаемся…» здесь было бы неправдой:
                // переподключение уже было, а фоновый догон после такого отказа замирает.
                return "Сессия недействительна. Откройте чат заново."
            case _ where status == 401:
                return "Сессия истекла. Откройте чат заново."
            default:
                return "Сервер недоступен (\(status)). Попробуйте ещё раз."
            }
        case .network:
            return "Нет связи с сервером. Проверьте интернет и повторите."
        case let .stream(code, _):
            return code == "ai_unavailable"
                ? "ИИ временно недоступен. Попробуйте ещё раз."
                : "Соединение прервано. Попробуйте ещё раз."
        case .invalidResponse:
            return "Неожиданный ответ сервера."
        case .cancelled:
            return "Отменено."
        }
    }

    public var errorDescription: String? { userMessage }
}

// MARK: - Модели ответов

/// Что сервер сделал с `identityToken`. Приходит В ОТВЕТЕ регистрации: провал проверки
/// SOFT — сессия живёт, но пользователь анонимен, и без этого поля интегратор узнать об
/// этом не может (единственным следом был бы серверный лог).
public enum IdentityStatus: String, Equatable {
    /// Токен не передавали — анонимная сессия.
    case notProvided = "not_provided"
    /// Идентичность подтверждена.
    case verified
    /// У приложения не настроен секрет подписи — токен проверить нечем.
    case notConfigured = "not_configured"
    /// Подпись верна, но токен выпущен давно (сервер принимает только свежие).
    case stale
    /// Подпись, срок или привязка к устройству не сошлись.
    case rejected
}

public struct MobileSession: Equatable {
    public let jwt: String
    public let expiresIn: Int
    /// Серверный id устройства. Тред диалога ключуется на нём.
    public let deviceId: String
    /// Приложение зарегистрировано, но аттестацию ещё не проходило.
    public let attestationRequired: Bool
    public let identityStatus: IdentityStatus
}

public struct HistoryMessage: Equatable {
    public let id: Int
    public let role: String
    public let content: String
    public let createdAt: Date?
    /// `ai` | `manager` у ответов ассистентской роли, `nil` у остальных. Сервер отдаёт поле
    /// с 2026-08-23; у старых сборок платформы его нет — тогда автор считается ботом, как и
    /// считался раньше.
    public let authorKind: String?
    /// Подпись менеджера для UI. Может быть `nil` даже при `authorKind == "manager"`.
    public let authorName: String?

    public init(
        id: Int,
        role: String,
        content: String,
        createdAt: Date?,
        authorKind: String? = nil,
        authorName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.authorKind = authorKind
        self.authorName = authorName
    }
}

/// Страница истории. `mode` отдаёт тот же роут: два эндпоинта одного канала не имеют права
/// разойтись в том, кто сейчас отвечает пользователю.
public struct HistoryPage: Equatable {
    public let messages: [HistoryMessage]
    public let hasMore: Bool
    public let mode: ChatMode
}

// MARK: - Отложенный выход

/// Флаг «пользователь вышел, сервер об этом ещё не знает».
///
/// Живёт в `UserDefaults`, а не в памяти: регистрация ленивая (первый показ экрана), и
/// между `identify(token: nil)` и ней приложение успевают убить. Потеряй мы сигнал —
/// устройство осталось бы связанным с прежним человеком, и следующий, кто откроет чат на
/// этом телефоне, увидел бы его переписку.
///
/// Снимается ТОЛЬКО подтверждением сервера (`identity.unlinked` в ответе регистрации).
/// Сервер старше 0.2.9 поле `logout` молча игнорирует и `unlinked` не присылает — тогда
/// флаг шлётся снова при каждой регистрации, пока сервер не обновится.
///
/// Значение — `<installationId>|<метка выхода>`, а не `true`:
///   • идентификатор установки: выход относится к строке устройства ЭТОЙ установки. Флаг,
///     оставшийся от прежней (`reset()`, гонка записи с ним), новой не касается — чужой
///     флаг отвязал бы уже новую связь;
///   • метка: снимать флаг можно только тем ответом, который его и вёз. Новый выход, записанный,
///     пока регистрация летела, получает новую метку и переживает её ответ.
///
/// К ключу приложения флаг не привязан сознательно: выход бывает до `configure(...)`, когда
/// ключа ещё нет, а строка устройства на сервере ключуется идентификатором установки.
struct IdentityFlagStore {
    static let pendingLogoutKey = "meerbot.pendingLogout"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Флаг этой установки — ровно в том виде, в каком он лежит (его и надо сверять при снятии).
    /// Флаг другой установки стирается: применять его некуда, а хранить — значит однажды
    /// применить не к той связи.
    func pendingLogout(installationId: String) -> String? {
        guard let raw = defaults.string(forKey: Self.pendingLogoutKey) else { return nil }
        guard raw.hasPrefix(installationId + "|") else {
            defaults.removeObject(forKey: Self.pendingLogoutKey)
            return nil
        }
        return raw
    }

    func markLogout(installationId: String) {
        defaults.set("\(installationId)|\(UUID().uuidString)", forKey: Self.pendingLogoutKey)
    }

    /// Снять флаг, только если он всё ещё тот, что ушёл на сервер.
    func clearLogout(ifStill sent: String) {
        guard defaults.string(forKey: Self.pendingLogoutKey) == sent else { return }
        defaults.removeObject(forKey: Self.pendingLogoutKey)
    }

    func clearAll() {
        defaults.removeObject(forKey: Self.pendingLogoutKey)
    }
}

/// Кто применён последним — чтобы после перезапуска приложения первый `identify` того же
/// человека не считался сменой (иначе он чистил бы ленту и обрывал ответ на каждом холодном
/// старте).
///
/// Хранится SHA-256 от пары «установка + `sub`», а не сам `sub`: это id пользователя в
/// системе интегратора, и лежать открытым текстом в `UserDefaults` (он попадает в бэкапы)
/// ему незачем. Для сравнения хэша достаточно. Установка в хэше — по той же причине, что и у
/// флага выхода: после `reset()` прежний человек к новой установке не относится.
struct AppliedIdentityStore {
    static let key = "meerbot.appliedIdentity"

    let defaults: UserDefaults

    func digest(subject: String, installationId: String) -> String {
        let bytes = SHA256.hash(data: Data("\(installationId)\n\(subject)".utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    var current: String? {
        get { defaults.string(forKey: Self.key) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// Как новый identity-токен соотносится с прежним.
enum IdentityChange: Equatable {
    /// Свежий токен того же человека: связь та же, лента та же.
    case refresh
    /// Другой человек, первый вход или токена больше нет. `unlinkPrevious` — связь, которая
    /// могла остаться у устройства, надо разорвать, даже если токен нового сервер не примет:
    /// клиент пишет флаг выхода. `false` — токена нет (это не выход) либо флаг уже записал
    /// вызывающий (`MeerBot` для токена, пришедшего до `configure`).
    case subject(unlinkPrevious: Bool)
    /// Выход.
    case logout
}

// MARK: - Клиент

/// Потокобезопасный клиент платформы: хранит JWT, обновляет его по истечении и стримит ответы.
public actor APIClient {

    private let config: MeerBotConfiguration
    /// Стабильный идентификатор установки — уходит в `deviceToken` (см. шапку файла).
    private let installationId: String
    private let visitorUuid: String
    private let session: URLSession
    private let flagStore: IdentityFlagStore

    private var jwt: String?
    private var jwtExpiresAt: Date?
    /// Единственная выполняющаяся операция регистрации — чтобы параллельные отправки
    /// не выписывали по своему JWT (сервер держит jti-allowlist, лишние токены — мусор).
    private var refreshTask: Task<String, Error>?

    /// Поколение identity: растёт при смене ЧЕЛОВЕКА (другой `sub`, первый вход) и при выходе.
    ///
    /// Регистрация, отправленная ДО смены, возвращает JWT прежнего устройства — например,
    /// ещё связанного с вышедшим пользователем. Сохрани мы его, чат ходил бы под чужой
    /// связью до истечения токена. Ответ с устаревшим поколением отбрасывается целиком.
    ///
    /// Свежий токен ТОГО ЖЕ человека поколение не двигает. Хост выпускает токен на каждый
    /// вход в чат, и два таких вызова во время отправки исчерпывали попытки регистрации —
    /// сообщение не уходило. А отбрасывать там нечего: ответ описывает связь того же
    /// человека. Для него есть `tokenRevision`.
    private var generation = 0
    /// Ревизия токена: растёт на каждый `applyIdentity`, включая свежий токен того же `sub`.
    /// Ответ регистрации, отправленной со старым токеном того же человека, запросу, который
    /// её ждал, отдаётся, но НЕ кэшируется: иначе свежий токен (например, вместо устаревшего,
    /// давшего `stale`) не дошёл бы до сервера, пока не истечёт выданный JWT.
    private var tokenRevision = 0
    /// Сколько раз регистрация повторяется, если identity менялась, пока запрос летел.
    private static let maxRegisterAttempts = 2

    /// Подписанный бэкендом интегратора identity-токен. Уходит в СЛЕДУЮЩУЮ регистрацию:
    /// связь устанавливается только там, чат читает уже подтверждённый claim.
    private var identityToken: String?
    /// Результат последней проверки identity — для диагностики на стороне хоста.
    public private(set) var identityStatus: IdentityStatus = .notProvided

    /// Диалог текущей сессии. Приходит событием `meta`; в запросы НЕ уходит — сервер резолвит
    /// тред по паре (приложение, устройство).
    public private(set) var conversationId: Int?
    /// id последнего известного сообщения — точка догона после обрыва.
    public private(set) var lastMessageId: Int?

    public init(
        config: MeerBotConfiguration,
        visitorUuid: String,
        installationId: String,
        sessionConfiguration: URLSessionConfiguration = APIClient.defaultSessionConfiguration()
    ) {
        self.init(
            config: config,
            visitorUuid: visitorUuid,
            installationId: installationId,
            sessionConfiguration: sessionConfiguration,
            flagStore: IdentityFlagStore()
        )
    }

    /// `flagStore` — отдельно ради тестов: им нужен свой `UserDefaults(suiteName:)`, а не
    /// общий `.standard`, который переживает прогон.
    init(
        config: MeerBotConfiguration,
        visitorUuid: String,
        installationId: String,
        sessionConfiguration: URLSessionConfiguration,
        flagStore: IdentityFlagStore
    ) {
        self.config = config
        self.visitorUuid = visitorUuid
        self.installationId = installationId
        self.session = URLSession(configuration: sessionConfiguration)
        self.flagStore = flagStore
    }

    public static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        // SSE-поток живёт до 30 минут (max lifetime на сервере) — ресурсный таймаут не должен
        // резать его раньше.
        cfg.timeoutIntervalForResource = 1_860
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["Accept-Language": Locale.preferredLanguages.first ?? "ru"]
        return cfg
    }

    public func setConversationId(_ id: Int?) { conversationId = id }

    /// Задать identity-токен. Действующий JWT сбрасывается сразу: связь устанавливается
    /// только регистрацией, и следующий запрос её выполнит.
    ///
    /// `nil` здесь — «токена нет», а НЕ выход: связь на сервере остаётся. Выход — `logout()`.
    ///
    /// Смена человека определяется по `sub` против токена, заданного в ЭТОМ экземпляре.
    /// Сменой считается любой токен, кроме свежего токена того же `sub`: другой `sub`, `sub`,
    /// который не читается, и первый токен экземпляра (кто был связан с устройством до него,
    /// экземпляр не знает). Смена пишет флаг выхода: связь прежнего будет разорвана следующей
    /// регистрацией, даже если токен нового сервер не примет. Лишней отставки флаг не даёт:
    /// тот же `sub` с подписанным токеном и анонимная строка сервер оставляет как есть.
    /// `MeerBot.identify` сравнивает с сохранённым между запусками.
    public func setIdentityToken(_ token: String?) {
        let change: IdentityChange
        if let token, let current = identityToken,
           Self.subjectKey(of: token) == Self.subjectKey(of: current) {
            change = .refresh
        } else {
            change = .subject(unlinkPrevious: token != nil)
        }
        applyIdentity(token, change: change)
    }

    /// Пользователь вышел: следующая регистрация отвяжет устройство на сервере.
    ///
    /// Флаг пишется на диск (см. `IdentityFlagStore`) и шлётся, пока сервер не подтвердит.
    /// Прежний тред остаётся за прежним пользователем, новая сессия начинается с пустой ленты.
    public func logout() {
        applyIdentity(nil, change: .logout)
    }

    /// Применить identity. Решение, КАКАЯ это смена, принимает вызывающий: только
    /// `MeerBot` знает, кто был применён до перезапуска приложения.
    func applyIdentity(_ token: String?, change: IdentityChange) {
        identityToken = token
        tokenRevision += 1
        invalidateToken()
        switch change {
        case .refresh:
            return
        case .subject(unlinkPrevious: true), .logout:
            // Переключение без выхода тоже рвёт связь прежнего: иначе при токене нового,
            // который сервер не принял (`stale`, `rejected`), устройство осталось бы за
            // прежним человеком, и новый увидел бы его тред.
            //
            // `MeerBot.identify` флаг уже записал, и здесь он пишется ЕЩЁ РАЗ — намеренно.
            // Снятие флага (`clearLogout(ifStill:)`) — чтение, сравнение и удаление без
            // атомарности, а `UserDefaults` пишет главный актор, не этот. Ответ регистрации,
            // снимающий ПРЕЖНИЙ флаг, мог попасть между записью нового и его удалением и
            // стереть его. Запись здесь идёт на акторе клиента, то есть строго после любого
            // снятия, начатого до смены, а `generation` ниже отбросит ответы, начатые до неё:
            // после этой строки флаг нового выхода уже никто не снимет, кроме его же ответа.
            flagStore.markLogout(installationId: installationId)
        case .subject(unlinkPrevious: false):
            break
        }
        generation += 1
        // Диалог, курсор и статус описывают прежнего человека.
        conversationId = nil
        lastMessageId = nil
        identityStatus = .notProvided
    }

    /// Ключ сравнения «тот же человек»: `sub`, а без него — сам токен.
    static func subjectKey(of token: String) -> String {
        MeerBot.identitySubject(of: token) ?? token
    }

    // MARK: Регистрация устройства (она же — открытие сессии)

    /// Зарегистрировать устройство и получить JWT. Идемпотентно: повторный вызов обновляет
    /// строку устройства (`upsert` по паре «приложение + идентификатор установки») и выдаёт
    /// новый токен — тред при этом ТОТ ЖЕ. Исключение — отложенный выход: регистрация с
    /// `logout: true` уводит связанную строку в отставку, и тред начинается новый.
    ///
    /// Если сменился человек, пока запрос летел, ответ отбрасывается и регистрация
    /// повторяется; не успела и вторая — `MeerBotError.cancelled`. Свежий токен того же
    /// человека попыток не тратит (см. `generation`).
    @discardableResult
    public func openSession() async throws -> MobileSession {
        guard !config.apiKey.isEmpty else { throw MeerBotError.notConfigured }

        for _ in 0 ..< Self.maxRegisterAttempts {
            if let session = try await register() { return session }
        }
        throw MeerBotError.cancelled
    }

    /// Одна попытка регистрации. `nil` — ответ относится к прежней identity и отброшен.
    private func register() async throws -> MobileSession? {
        // Поколение и флаг фиксируются на момент сборки тела: именно они описывают, ЧТО
        // сервер получил, а к ответу состояние актора может уже быть другим.
        let startedGeneration = generation
        let startedRevision = tokenRevision
        let logoutSent = flagStore.pendingLogout(installationId: installationId)

        var request = makeRequest(path: "/api/v1/mobile/register", method: "POST")
        var body: [String: Any] = [
            "key": config.apiKey,
            // Идентификатор установки, а не APNs-токен — см. шапку файла.
            "deviceToken": installationId,
            "platform": "ios",
            "visitorUuid": visitorUuid,
            "sdkVersion": config.sdkVersion,
        ]
        if let identityToken { body["identityToken"] = identityToken }
        // Отдельное поле, а не `identityToken: null`: у сервера поле токена — строка, и
        // `null` вернул бы 400. Старый сервер незнакомое поле игнорирует.
        if logoutSent != nil { body["logout"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        guard generation == startedGeneration else { return nil }
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let token = json["jwt"] as? String,
            let deviceId = json["deviceId"] as? String
        else {
            throw MeerBotError.invalidResponse
        }

        // `expiresIn` обязателен по контракту, но его отсутствие не повод падать: без него
        // токен считаем живым минуту — следующий запрос просто перевыпустит его.
        let expiresIn = (json["expiresIn"] as? Int) ?? 60
        let identity = json["identity"] as? [String: Any]
        let status = (identity?["status"] as? String)
            .flatMap(IdentityStatus.init(rawValue:)) ?? .notProvided
        // Токен того же человека обновился в полёте: этот JWT отдаём ждущему запросу (связь
        // та же), но не кэшируем — следующий запрос зарегистрируется уже со свежим токеном.
        // Статус тоже не публикуем: он о СТАРОМ токене, и `stale` устаревшего токена,
        // пришедший после замены его свежим, хост принял бы за провал свежего.
        if tokenRevision == startedRevision {
            jwt = token
            jwtExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            identityStatus = status
        }

        // Сервер 0.2.9+ присылает `unlinked` всегда — само его наличие значит «выход принят»
        // (значение `false` — отвязывать было нечего). Нет поля — сервер старый: флаг остаётся.
        // Снимается только тот флаг, что ушёл в запросе: выход, записанный в полёте, остаётся.
        if let logoutSent, identity?["unlinked"] is Bool {
            flagStore.clearLogout(ifStill: logoutSent)
        }

        return MobileSession(
            jwt: token,
            expiresIn: expiresIn,
            deviceId: deviceId,
            attestationRequired: (json["attestationRequired"] as? Bool) ?? false,
            identityStatus: status
        )
    }

    /// Действующий JWT: переиспользуем, пока до истечения больше минуты, иначе — новая
    /// регистрация. Параллельные вызовы разделяют одну операцию обновления.
    public func validToken() async throws -> String {
        if let jwt, let expiresAt = jwtExpiresAt, expiresAt.timeIntervalSinceNow > 60 {
            return jwt
        }
        if let refreshTask { return try await refreshTask.value }

        let task = Task<String, Error> { [self] in
            try await openSession().jwt
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Пометить текущий токен недействительным (сервер ответил 401 `jwt_*`/`device_*`).
    public func invalidateToken() {
        jwt = nil
        jwtExpiresAt = nil
    }

    // MARK: История (догон после обрыва)

    /// История диалога. Без `since` возвращает последние `limit` сообщений треда — именно
    /// это нужно для замены ленты после обрыва. `since` — инкрементальный догон.
    ///
    /// `conversationId` не передаётся: тред резолвится по устройству из токена. До первого
    /// сообщения пользователя диалога ещё нет — сервер отвечает пустой лентой, а не ошибкой.
    @discardableResult
    public func history(since: Int? = nil, limit: Int = 50) async throws -> HistoryPage {
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("/api/v1/mobile/messages"),
            resolvingAgainstBaseURL: false
        )
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let since {
            query.append(URLQueryItem(name: "since", value: String(since)))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw MeerBotError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request)
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")

        let data = try await performAuthorized(request)
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let raw = json["messages"] as? [[String: Any]]
        else {
            throw MeerBotError.invalidResponse
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let messages = raw.compactMap { item -> HistoryMessage? in
            guard
                let id = item["id"] as? Int,
                let role = item["role"] as? String,
                let content = item["content"] as? String
            else { return nil }
            return HistoryMessage(
                id: id,
                role: role,
                content: content,
                createdAt: (item["createdAt"] as? String).flatMap { formatter.date(from: $0) },
                authorKind: item["authorKind"] as? String,
                authorName: item["authorName"] as? String
            )
        }
        if let last = messages.last?.id { lastMessageId = last }

        return HistoryPage(
            messages: messages,
            hasMore: (json["hasMore"] as? Bool) ?? false,
            mode: ChatMode(rawValue: (json["mode"] as? String) ?? "") ?? .ai
        )
    }

    // MARK: Стрим ответа

    /// Отправить сообщение и получить поток событий.
    ///
    /// Поведение при обрыве: итерация выбрасывает `MeerBotError.network` — уже полученные
    /// события остаются доставленными, вызывающая сторона решает, догонять ли историю.
    /// Истёкший JWT (401 `jwt_*`) или снятое с регистрации устройство (401 `device_*`)
    /// обновляются прозрачно, запрос повторяется РОВНО один раз.
    public func sendMessage(_ text: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(text: text, allowRetry: true, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MeerBotError.cancelled)
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        text: String,
        allowRetry: Bool,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var request = makeRequest(path: "/api/v1/mobile/chat/stream", method: "POST")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        // Тело — только текст: диалог выбирает сервер по устройству из токена.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": text])

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError {
            throw MeerBotError.network(code: urlError.code, message: urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw MeerBotError.invalidResponse }

        if http.statusCode >= 400 {
            var payload = Data()
            for try await byte in bytes { payload.append(byte) }
            let error = Self.decodeError(status: http.statusCode, data: payload)
            // Единственный автоматический повтор — на токен, который лечится перерегистрацией.
            // `channel_mismatch` сюда НЕ попадает (403 и другой код): токен не протух, он от
            // другого канала, и перевыпуск его не исправит.
            if Self.isRecoverableBySession(status: http.statusCode, code: error.code), allowRetry {
                invalidateToken()
                try await runStream(text: text, allowRetry: false, continuation: continuation)
                return
            }
            throw error
        }

        let parser = SSEParser()
        var buffer = Data()
        buffer.reserveCapacity(4096)

        do {
            for try await byte in bytes {
                buffer.append(byte)
                guard byte == 0x0A else { continue } // граница события возможна только после \n
                for event in parser.feed(buffer) {
                    emit(event, to: continuation)
                }
                buffer.removeAll(keepingCapacity: true)
            }
        } catch let urlError as URLError {
            throw MeerBotError.network(code: urlError.code, message: urlError.localizedDescription)
        }

        if !buffer.isEmpty {
            for event in parser.feed(buffer) {
                emit(event, to: continuation)
            }
        }
        // Поток закрылся без завершающей пустой строки — добираем последний блок.
        for event in parser.flush() {
            emit(event, to: continuation)
        }
    }

    private func emit(
        _ raw: SSEEvent,
        to continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) {
        guard let event = ChatStreamEvent.from(raw) else { return }
        if case let .meta(id, _) = event, id > 0 { conversationId = id }
        if case let .managerMessage(message) = event, message.messageId > 0 {
            lastMessageId = message.messageId
        }
        continuation.yield(event)
    }

    // MARK: Транспорт

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&request)
        return request
    }

    private func applyCommonHeaders(_ request: inout URLRequest) {
        // Origin не шлём: мобильные роуты его не проверяют, а требование вписать
        // `https://<bundleId>` в разрешённые домены ключа было платой за чужой (виджетный)
        // контракт.
        request.setValue(config.sdkVersion, forHTTPHeaderField: "X-SDK-Version")
    }

    /// Запрос без Authorization (регистрация устройства).
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw MeerBotError.network(code: urlError.code, message: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MeerBotError.invalidResponse }
        if http.statusCode >= 400 {
            throw Self.decodeError(status: http.statusCode, data: data)
        }
        return data
    }

    /// Запрос с Authorization: 401 по протухшему JWT или снятому устройству обновляет сессию
    /// и повторяется один раз.
    private func performAuthorized(_ request: URLRequest, allowRetry: Bool = true) async throws -> Data {
        do {
            return try await perform(request)
        } catch let error as MeerBotError {
            guard
                allowRetry,
                case let .http(status, code, _) = error,
                Self.isRecoverableBySession(status: status, code: code)
            else { throw error }

            invalidateToken()
            var retry = request
            retry.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            return try await performAuthorized(retry, allowRetry: false)
        }
    }

    /// 401, который лечит новая регистрация: протухший JWT (`jwt_*`) или токен устройства,
    /// которого больше нет (`device_not_found` — строку увёл в отставку выход или смена
    /// пользователя; `device_claim_missing` — токен старого формата). До 0.2.9 на `device_*`
    /// экран обещал «Переподключаемся…», а переподключения не было.
    static func isRecoverableBySession(status: Int, code: String) -> Bool {
        guard status == 401 else { return false }
        return code.hasPrefix("jwt_") || code == "device_not_found" || code == "device_claim_missing"
    }

    /// Ошибки платформы приходят в форме Stripe/OpenAI: `{error:{type,code,message}}`.
    /// Форма общая у обоих мобильных роутов: `widgetError` (регистрация) и `mobileChatError`
    /// (чат, история) собирают один и тот же конверт.
    static func decodeError(status: Int, data: Data) -> MeerBotError {
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else {
            return .http(status: status, code: "http_\(status)", message: "HTTP \(status)")
        }
        return .http(
            status: status,
            code: (error["code"] as? String) ?? "http_\(status)",
            message: (error["message"] as? String) ?? "HTTP \(status)"
        )
    }

    private static func normalize(_ error: Error) -> Error {
        if let meerBotError = error as? MeerBotError { return meerBotError }
        if let urlError = error as? URLError {
            return MeerBotError.network(code: urlError.code, message: urlError.localizedDescription)
        }
        return error
    }
}
