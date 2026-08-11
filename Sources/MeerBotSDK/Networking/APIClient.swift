// MeerBot iOS SDK — HTTP-клиент платформы.
//
// ── Какой контракт настоящий (сверено по коду agentbot-platform на 2026-08-11) ──────────
//
// ЧАТ живёт в `/api/v1/widget/*` и НИГДЕ больше:
//   POST /api/v1/widget/session      — handshake pk_live_* + Origin → JWT (15 мин)
//   POST /api/v1/widget/chat/stream  — SSE-поток ответа (тело: {message, conversationId?})
//   GET  /api/v1/widget/messages     — догон истории после обрыва (?conversationId&since)
//
// `/api/v1/mobile/*` — ТОЛЬКО регистрация устройства и аттестация; эндпоинта чата там нет:
//   POST /api/v1/mobile/register     — upsert MobileDevice(APNs-токен) → JWT
//   POST /api/v1/mobile/attestation  — App Attest (на бэкенде пока заглушка)
//
// Важное следствие (см. README, раздел «Два ключа»): JWT из `/mobile/register` НЕ подходит
// для `/widget/chat/stream`. Он подписан с `aud = ClientMobileApp.id`, а chat/stream требует
// `aud == ClientWebsiteWidget.id` того же ключа (`findActiveWidgetByApiKey`), и эти таблицы —
// разные пространства id: `apiKeyId` уникален в каждой отдельно, у mobile-ключа строки
// виджета нет вовсе → гарантированный `403 widget_not_active`. Поэтому чат ходит по ключу
// headless-виджета, а пуши — по ключу мобильного приложения.

import Foundation

// MARK: - Конфигурация

public struct MeerBotConfiguration {
    /// pk_live_* headless-виджета (кабинет → Каналы → виджет). Транспорт чата.
    public let apiKey: String
    /// pk_live_* мобильного приложения (кабинет → Мобильные приложения). Только для APNs.
    public let pushApiKey: String?
    public let baseURL: URL
    /// Значение заголовка `Origin`. Должно входить в «разрешённые домены» ключа, иначе
    /// handshake вернёт 401 key_invalid. Дефолт — `https://<bundleId>`.
    ///
    /// Почему https, а не `mobile://`: кабинет принимает в разрешённые домены ТОЛЬКО
    /// https-origin (`isValidOriginPattern` в api/client/widget/route.ts), так что схему
    /// `mobile://` туда физически не вписать.
    public let origin: String
    public let sdkVersion: String

    public init(
        apiKey: String,
        pushApiKey: String? = nil,
        baseURL: URL = URL(string: MeerBotPlatform.apiBaseUrl)!,
        origin: String? = nil,
        sdkVersion: String = MeerBotPlatform.version
    ) {
        self.apiKey = apiKey
        self.pushApiKey = pushApiKey
        self.baseURL = baseURL
        self.origin = origin ?? MeerBotConfiguration.defaultOrigin()
        self.sdkVersion = sdkVersion
    }

    static func defaultOrigin() -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown.app"
        return "https://\(bundleId)"
    }
}

// MARK: - Ошибки

public enum MeerBotError: Error, LocalizedError {
    /// `configure(...)` не вызван (или вызван с пустым ключом).
    case notConfigured
    /// Сервер ответил кодом ≥400. `code` — машинный код платформы (`key_invalid`,
    /// `rate_limit_ip`, `quota_exceeded`, `jwt_expired`, …).
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
    public var userMessage: String {
        switch self {
        case .notConfigured:
            return "Чат не настроен. Вызовите MeerBot.shared.configure(apiKey:)."
        case let .http(status, code, _):
            switch code {
            case "key_invalid":
                return "Неверный ключ или домен приложения не разрешён в кабинете."
            case "widget_not_active":
                return "Канал отключён в кабинете."
            case "quota_exceeded":
                return "Дневной лимит расходов исчерпан."
            case _ where code.hasPrefix("rate_limit"):
                return "Слишком много сообщений. Попробуйте через минуту."
            case _ where status == 401:
                return "Сессия истекла. Переподключаемся…"
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

public struct WidgetSession: Equatable {
    public let jwt: String
    public let expiresIn: Int
    public let conversationId: Int?
    public let mode: ChatMode
    public let title: String?
    public let greeting: String?
}

public struct HistoryMessage: Equatable {
    public let id: Int
    public let role: String
    public let content: String
    public let createdAt: Date?
}

public struct DeviceRegistration: Equatable {
    public let deviceId: String
    public let attestationRequired: Bool
}

// MARK: - Клиент

/// Потокобезопасный клиент платформы: хранит JWT, обновляет его по истечении и стримит ответы.
public actor APIClient {

    private let config: MeerBotConfiguration
    private let session: URLSession
    private let visitorUuid: String

    private var jwt: String?
    private var jwtExpiresAt: Date?
    /// Единственная выполняющаяся операция handshake — чтобы параллельные отправки
    /// не выписывали по своему JWT (сервер держит jti-allowlist, лишние токены — мусор).
    private var refreshTask: Task<String, Error>?

    /// Диалог текущей сессии. Проставляется из `meta`/handshake, уходит в тело следующего запроса.
    public private(set) var conversationId: Int?
    /// id последнего известного сообщения — точка догона после обрыва.
    public private(set) var lastMessageId: Int?

    public init(
        config: MeerBotConfiguration,
        visitorUuid: String,
        sessionConfiguration: URLSessionConfiguration = APIClient.defaultSessionConfiguration()
    ) {
        self.config = config
        self.visitorUuid = visitorUuid
        self.session = URLSession(configuration: sessionConfiguration)
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

    // MARK: Handshake

    /// Открыть сессию виджета. Идемпотентно: повторный вызов выдаёт новый JWT на тот же visitorUuid.
    @discardableResult
    public func openSession() async throws -> WidgetSession {
        var request = makeRequest(path: "/api/v1/widget/session", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": config.apiKey,
            "visitorUuid": visitorUuid,
            "hostOrigin": config.origin,
        ])

        let data = try await perform(request)
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let token = json["jwt"] as? String,
            let expiresIn = json["expiresIn"] as? Int
        else {
            throw MeerBotError.invalidResponse
        }

        jwt = token
        jwtExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

        let widget = json["widget"] as? [String: Any]
        let restored = json["conversationId"] as? Int
        if let restored { conversationId = restored }

        return WidgetSession(
            jwt: token,
            expiresIn: expiresIn,
            conversationId: restored,
            mode: ChatMode(rawValue: (json["mode"] as? String) ?? "") ?? .ai,
            title: widget?["title"] as? String,
            greeting: widget?["greeting"] as? String
        )
    }

    /// Действующий JWT: переиспользуем, пока до истечения больше минуты, иначе — новый handshake.
    /// Параллельные вызовы разделяют одну операцию обновления.
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

    /// Пометить текущий токен недействительным (сервер ответил 401 jwt_*).
    public func invalidateToken() {
        jwt = nil
        jwtExpiresAt = nil
    }

    // MARK: Регистрация устройства (APNs)

    /// Зарегистрировать APNs-токен. Требует ключ мобильного приложения (`pushApiKey`).
    @discardableResult
    public func registerDevice(apnsToken: String) async throws -> DeviceRegistration {
        guard let pushApiKey = config.pushApiKey, !pushApiKey.isEmpty else {
            throw MeerBotError.notConfigured
        }
        var request = makeRequest(path: "/api/v1/mobile/register", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": pushApiKey,
            "deviceToken": apnsToken,
            "platform": "ios",
            "visitorUuid": visitorUuid,
            "sdkVersion": config.sdkVersion,
        ])

        let data = try await perform(request)
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let deviceId = json["deviceId"] as? String
        else {
            throw MeerBotError.invalidResponse
        }
        // JWT из этого ответа СОЗНАТЕЛЬНО не сохраняем: он подписан на другое пространство id
        // и для /widget/chat/stream невалиден (см. шапку файла).
        return DeviceRegistration(
            deviceId: deviceId,
            attestationRequired: (json["attestationRequired"] as? Bool) ?? false
        )
    }

    // MARK: История (догон после обрыва)

    /// История диалога. Без `since` возвращает последние `limit` сообщений треда — именно
    /// это нужно для замены ленты после обрыва. `since` — инкрементальный догон.
    public func history(since: Int? = nil, limit: Int = 50) async throws -> [HistoryMessage] {
        guard let conversationId else { return [] }
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("/api/v1/widget/messages"),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(name: "conversationId", value: String(conversationId)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
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
                createdAt: (item["createdAt"] as? String).flatMap { formatter.date(from: $0) }
            )
        }
        if let last = messages.last?.id { lastMessageId = last }
        return messages
    }

    // MARK: Стрим ответа

    /// Отправить сообщение и получить поток событий.
    ///
    /// Поведение при обрыве: итерация выбрасывает `MeerBotError.network` — уже полученные
    /// события остаются доставленными, вызывающая сторона решает, догонять ли историю.
    /// Истёкший JWT (401 `jwt_*`) обновляется прозрачно, запрос повторяется РОВНО один раз.
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
        var request = makeRequest(path: "/api/v1/widget/chat/stream", method: "POST")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["message": text]
        if let conversationId { body["conversationId"] = conversationId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
            // Единственный автоматический повтор — на протухший токен.
            if http.statusCode == 401, error.code.hasPrefix("jwt_"), allowRetry {
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
        // Origin в URLSession — обычный заголовок (не запрещённый, в отличие от браузера):
        // сервер пинует по нему публичный ключ и сверяет с `oid` в JWT.
        request.setValue(config.origin, forHTTPHeaderField: "Origin")
        request.setValue(config.sdkVersion, forHTTPHeaderField: "X-SDK-Version")
    }

    /// Запрос без Authorization (handshake, регистрация устройства).
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

    /// Запрос с Authorization: 401 по протухшему JWT обновляет сессию и повторяется один раз.
    private func performAuthorized(_ request: URLRequest, allowRetry: Bool = true) async throws -> Data {
        do {
            return try await perform(request)
        } catch let error as MeerBotError {
            guard
                allowRetry,
                case let .http(status, code, _) = error,
                status == 401,
                code.hasPrefix("jwt_")
            else { throw error }

            invalidateToken()
            var retry = request
            retry.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            return try await performAuthorized(retry, allowRetry: false)
        }
    }

    /// Ошибки платформы приходят в форме Stripe/OpenAI: `{error:{type,code,message}}`.
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
