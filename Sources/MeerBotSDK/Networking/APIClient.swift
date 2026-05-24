// MeerBot iOS SDK — Phase 5.b: HTTP-клиент с поддержкой SSE.
// Использует URLSessionDataDelegate для построчного парсинга event-stream.

import Foundation

public final class APIClient: NSObject {

    public struct Configuration {
        public let baseURL: URL
        public let pkLive: String
        public let origin: String

        public init(baseURL: URL, pkLive: String, origin: String) {
            self.baseURL = baseURL
            self.pkLive = pkLive
            self.origin = origin
        }
    }

    public enum APIError: Error {
        case http(status: Int, message: String)
        case decoding(Error)
        case network(Error)
        case cancelled
    }

    private let config: Configuration
    private var jwt: String?
    private var session: URLSession!

    public init(config: Configuration) {
        self.config = config
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }

    public func setJWT(_ token: String) {
        self.jwt = token
    }

    // MARK: - Bootstrap session

    public struct SessionResponse: Codable {
        public let jwt: String
        public let expiresIn: Int
        public let conversationId: Int?
    }

    public func createSession(visitorUuid: String, externalUserId: String?) async throws -> SessionResponse {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("/api/v1/widget/session"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.origin, forHTTPHeaderField: "Origin")

        var body: [String: Any] = [
            "key": config.pkLive,
            "visitorUuid": visitorUuid,
        ]
        if let externalUserId = externalUserId {
            body["externalUserId"] = externalUserId
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: 0, message: "no response")
        }
        if http.statusCode >= 400 {
            throw APIError.http(status: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(SessionResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Chat streaming via SSE

    public struct StreamChunk {
        public let event: String
        public let data: [String: Any]
    }

    /// Открыть SSE стрим. AsyncThrowingStream проксирует распарсенные события из event-stream.
    /// onComplete вызывается при нормальном завершении (event: done). Ошибки доставляются через throw.
    public func openChatStream(
        conversationId: Int?,
        content: String
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            guard let jwt = self.jwt else {
                continuation.finish(throwing: APIError.http(status: 401, message: "JWT not set"))
                return
            }
            var req = URLRequest(url: config.baseURL.appendingPathComponent("/api/v1/widget/chat/stream"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            req.setValue(config.origin, forHTTPHeaderField: "Origin")
            var body: [String: Any] = ["content": content]
            if let conversationId = conversationId {
                body["conversationId"] = conversationId
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let task = session.dataTask(with: req)
            let parser = SSEParser()

            class TaskDelegate: NSObject, URLSessionDataDelegate {
                let continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
                let parser: SSEParser
                init(continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation, parser: SSEParser) {
                    self.continuation = continuation
                    self.parser = parser
                }
                func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                    parser.feed(data) { event, payload in
                        continuation.yield(StreamChunk(event: event, data: payload))
                        if event == "done" || event == "close" {
                            continuation.finish()
                        }
                    }
                }
                func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                    if let error = error {
                        continuation.finish(throwing: APIError.network(error))
                    } else {
                        continuation.finish()
                    }
                }
            }

            let delegate = TaskDelegate(continuation: continuation, parser: parser)
            let sseSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let sseTask = sseSession.dataTask(with: req)

            continuation.onTermination = { @Sendable _ in
                sseTask.cancel()
            }
            sseTask.resume()
            _ = task // keep ref to avoid premature dealloc
        }
    }
}

/// Простой парсер Server-Sent Events: разбивает поток на пары event/data.
final class SSEParser {
    private var buffer = ""

    func feed(_ data: Data, onEvent: (String, [String: Any]) -> Void) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        while let range = buffer.range(of: "\n\n") {
            let chunk = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            parseChunk(chunk, onEvent: onEvent)
        }
    }

    private func parseChunk(_ chunk: String, onEvent: (String, [String: Any]) -> Void) {
        var event = "message"
        var dataLines: [String] = []
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let str = String(line)
            if str.hasPrefix("event: ") {
                event = String(str.dropFirst(7))
            } else if str.hasPrefix("data: ") {
                dataLines.append(String(str.dropFirst(6)))
            }
        }
        let dataStr = dataLines.joined(separator: "\n")
        guard let data = dataStr.data(using: .utf8) else { return }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            onEvent(event, ["raw": dataStr])
            return
        }
        onEvent(event, payload)
    }
}
