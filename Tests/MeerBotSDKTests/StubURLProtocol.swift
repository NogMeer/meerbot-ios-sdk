// Подменный транспорт для тестов: отдаёт заранее описанный ответ, умеет резать тело на
// чанки (проверка потоковой сборки) и обрывать соединение посреди потока.

import Foundation
import XCTest

struct StubResponse {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "text/event-stream"]
    /// Тело, нарезанное так, как его отдаёт сеть. Границы намеренно произвольные.
    var chunks: [Data] = []
    /// Если задано — после отдачи чанков соединение падает с этой ошибкой.
    var failure: URLError?
    /// Пауза перед каждым чанком и перед обрывом. Нужна там, где проверяется, что клиент
    /// УСПЕЛ обработать пришедшее до разрыва: мгновенная отдача всего тела одним махом —
    /// нереалистичная модель сети.
    var chunkDelay: TimeInterval = 0
    /// Ответ не уходит, пока тест не откроет ворота. Нужен там, где проверяется ПОРЯДОК
    /// событий («история пришла после отправки»): пауза по времени делала бы такой тест
    /// зависимым от планировщика, ворота — нет.
    var gate: StubGate?
    /// Подставить в тело ответа `clientMessageId` из ТЕЛА ЗАПРОСА вместо `$CLIENT_ID`.
    ///
    /// Иначе подтверждение приёма не проверить: идентификатор отправки рождается внутри
    /// контроллера в момент `send`, а ответ стаба описывается заранее. Сервер в этом месте
    /// ведёт себя так же — возвращает то, что получил.
    var echoesClientMessageId: Bool = false
    /// Чанки отданы, а завершения нет: сервер просто перестал слать байты и держит сокет.
    /// Так выглядит зависший стрим — единственный способ проверить, что `stop()` рвёт
    /// запрос сам, а не ждёт, пока это сделает таймаут сессии.
    var hangs: Bool = false

    static func json(_ object: [String: Any], status: Int = 200) -> StubResponse {
        StubResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            chunks: [try! JSONSerialization.data(withJSONObject: object)]
        )
    }

    static func sse(_ body: String, chunkSize: Int? = nil) -> StubResponse {
        let data = Data(body.utf8)
        guard let chunkSize else { return StubResponse(chunks: [data]) }
        var chunks: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(data.subdata(in: index ..< end))
            index = end
        }
        return StubResponse(chunks: chunks)
    }
}

/// Ворота для ответа стаба. Открываются один раз и навсегда: ответ, который очередь стаба
/// повторяет, после открытия отдаётся сразу.
final class StubGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func open() {
        condition.lock(); defer { condition.unlock() }
        isOpen = true
        condition.broadcast()
    }

    /// `false` — ворота так и не открыли: тест забыл про них, и зависать ему нельзя.
    fileprivate func waitUntilOpen(timeout: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isOpen {
            if !condition.wait(until: deadline) { return isOpen }
        }
        return true
    }
}

struct RecordedRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: [String: Any]?
}

final class StubURLProtocol: URLProtocol {

    /// Очередь ответов по пути запроса. Каждый вызов снимает первый ответ; если остался
    /// один — он повторяется (удобно для «сервер всегда отвечает так»).
    private static let lock = NSLock()
    private static var queues: [String: [StubResponse]] = [:]
    private static var recorded: [RecordedRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queues = [:]
        recorded = []
        completedByPath = [:]
        stoppedByPath = [:]
        lastClientMessageId = nil
    }

    /// Запрос уже завершён транспортом — отменять в нём нечего.
    private var finished = false

    static func enqueue(path: String, _ responses: StubResponse...) {
        lock.lock(); defer { lock.unlock() }
        queues[path, default: []].append(contentsOf: responses)
    }

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func requests(path: String) -> [RecordedRequest] {
        requests.filter { $0.url.path == path }
    }

    private static func next(for path: String) -> StubResponse? {
        lock.lock(); defer { lock.unlock() }
        guard var queue = queues[path], !queue.isEmpty else { return nil }
        let response = queue.count == 1 ? queue[0] : queue.removeFirst()
        queues[path] = queue
        return response
    }

    private static func record(_ request: RecordedRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.readBody(from: request)
        if let sent = body?["clientMessageId"] as? String, !sent.isEmpty {
            Self.rememberClientMessageId(sent)
        }
        Self.record(
            RecordedRequest(
                url: request.url!,
                method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            )
        )

        guard let stub = Self.next(for: path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        guard let gate = stub.gate else {
            deliver(stub, path: path)
            return
        }
        // Ждём ворота НЕ на потоке загрузки: URLSession крутит протоколы на общем потоке, и
        // заблокированный ответ задержал бы все остальные запросы теста — порядок, который
        // тест проверяет, стал бы невоспроизводимым.
        DispatchQueue.global().async { [self] in
            guard gate.waitUntilOpen(timeout: 5) else {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                Self.markCompleted(path)
                return
            }
            deliver(stub, path: path)
        }
    }

    private func deliver(_ stub: StubResponse, path: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        for chunk in stub.chunks {
            if stub.chunkDelay > 0 { Thread.sleep(forTimeInterval: stub.chunkDelay) }
            client?.urlProtocol(self, didLoad: stub.echoesClientMessageId ? Self.echoing(chunk) : chunk)
        }

        // Висящий ответ: байты кончились, а сокет открыт. Ни `didFinishLoading`, ни ошибки —
        // выход из такого стрима возможен только отменой запроса.
        if stub.hangs { return }

        if stub.failure != nil, stub.chunkDelay > 0 {
            Thread.sleep(forTimeInterval: stub.chunkDelay)
        }
        Self.lock.lock()
        finished = true
        Self.lock.unlock()
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        Self.markCompleted(path)
    }

    /// Последний `clientMessageId`, пришедший в теле запроса. Историю запрашивают GET-ом, а
    /// строка пользователя в ответе обязана нести тот же идентификатор, что ушёл в отправке.
    private static var lastClientMessageId: String?

    private static func rememberClientMessageId(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        lastClientMessageId = id
    }

    /// `$CLIENT_ID` → идентификатор отправки. Замена побайтовая, поэтому работает и в SSE, и
    /// в JSON-теле истории.
    private static func echoing(_ chunk: Data) -> Data {
        lock.lock()
        let id = lastClientMessageId ?? ""
        lock.unlock()
        guard let text = String(data: chunk, encoding: .utf8) else { return chunk }
        return Data(text.replacingOccurrences(of: "$CLIENT_ID", with: id).utf8)
    }

    private static var completedByPath: [String: Int] = [:]

    /// Сколько ответов по пути транспорт уже отдал целиком (или оборвал) — после ворот
    /// это единственный способ узнать, что запоздалый ответ долетел.
    static func completed(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return completedByPath[path] ?? 0
    }

    private static func markCompleted(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        completedByPath[path, default: 0] += 1
    }

    private static var stoppedByPath: [String: Int] = [:]

    /// Сколько запросов по пути URLSession отменила. Отмена доходит до транспорта только
    /// если её кто-то сделал: для проверки «`stop()` рвёт запрос в полёте» это и есть факт.
    static func stopped(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return stoppedByPath[path] ?? 0
    }

    override func stopLoading() {
        // `stopLoading` зовётся и после нормального завершения ответа, поэтому отменой
        // считается только остановка НЕзавершённого запроса.
        let path = request.url?.path ?? ""
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard !finished else { return }
        Self.stoppedByPath[path, default: 0] += 1
    }

    /// URLSession переносит `httpBody` в `httpBodyStream` — читаем оба варианта.
    private static func readBody(from request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension URLSessionConfiguration {
    static func stubbed() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        return cfg
    }
}
