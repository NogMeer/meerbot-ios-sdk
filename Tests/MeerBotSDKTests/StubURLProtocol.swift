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
    }

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
        Self.record(
            RecordedRequest(
                url: request.url!,
                method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.readBody(from: request)
            )
        )

        guard let stub = Self.next(for: path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        for chunk in stub.chunks {
            if stub.chunkDelay > 0 { Thread.sleep(forTimeInterval: stub.chunkDelay) }
            client?.urlProtocol(self, didLoad: chunk)
        }

        if stub.failure != nil, stub.chunkDelay > 0 {
            Thread.sleep(forTimeInterval: stub.chunkDelay)
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

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
