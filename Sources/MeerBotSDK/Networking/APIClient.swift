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
                // Токен от другого канала/устройства либо устройство снято с регистрации.
                // Обновление токена не помогает — нужна новая регистрация.
                return "Сессия недействительна. Переподключаемся…"
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
}

/// Страница истории. `mode` отдаёт тот же роут: два эндпоинта одного канала не имеют права
/// разойтись в том, кто сейчас отвечает пользователю.
public struct HistoryPage: Equatable {
    public let messages: [HistoryMessage]
    public let hasMore: Bool
    public let mode: ChatMode
}

// MARK: - Клиент

/// Потокобезопасный клиент платформы: хранит JWT, обновляет его по истечении и стримит ответы.
public actor APIClient {

    private let config: MeerBotConfiguration
    /// Стабильный идентификатор установки — уходит в `deviceToken` (см. шапку файла).
    private let installationId: String
    private let visitorUuid: String
    private let session: URLSession

    private var jwt: String?
    private var jwtExpiresAt: Date?
    /// Единственная выполняющаяся операция регистрации — чтобы параллельные отправки
    /// не выписывали по своему JWT (сервер держит jti-allowlist, лишние токены — мусор).
    private var refreshTask: Task<String, Error>?

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
        self.config = config
        self.visitorUuid = visitorUuid
        self.installationId = installationId
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

    /// Задать identity-токен. Применяется при следующей регистрации: чтобы связь установилась
    /// немедленно, вызывающий сбрасывает текущий токен (`MeerBot.identify` так и делает).
    public func setIdentityToken(_ token: String?) {
        identityToken = token
    }

    // MARK: Регистрация устройства (она же — открытие сессии)

    /// Зарегистрировать устройство и получить JWT. Идемпотентно: повторный вызов обновляет
    /// строку устройства (`upsert` по паре «приложение + идентификатор установки») и выдаёт
    /// новый токен — тред при этом ТОТ ЖЕ.
    @discardableResult
    public func openSession() async throws -> MobileSession {
        guard !config.apiKey.isEmpty else { throw MeerBotError.notConfigured }

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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
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
        jwt = token
        jwtExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

        let status = ((json["identity"] as? [String: Any])?["status"] as? String)
            .flatMap(IdentityStatus.init(rawValue:)) ?? .notProvided
        identityStatus = status

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

    /// Пометить текущий токен недействительным (сервер ответил 401 jwt_*).
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
                createdAt: (item["createdAt"] as? String).flatMap { formatter.date(from: $0) }
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
            // Единственный автоматический повтор — на протухший токен. `channel_mismatch`
            // сюда НЕ попадает (403 и другой код): токен не протух, он от другого канала,
            // и перевыпуск его не исправит.
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
