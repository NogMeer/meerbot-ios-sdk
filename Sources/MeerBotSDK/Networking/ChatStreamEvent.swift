// MeerBot iOS SDK — типизированные события чат-стрима.
//
// Соответствие событий бэкенду — `src/app/api/v1/mobile/chat/stream/route.ts`. Форма кадров
// намеренно совпадает с виджетной (`/api/v1/widget/chat/stream`), поэтому парсер один:
//   event: meta                 → {conversationId, mode}
//   (без event)                 → OpenAI-совместимый чанк {choices:[{delta:{content}}]}
//   data: [DONE]                → генерация AI завершена
//   event: manager_message      → {messageId, role, text, authorName, createdAt}
//   event: forwarded_to_manager → {mode} — диалог ведёт менеджер, модель не звалась
//   event: heartbeat            → {} каждые 15 с
//   event: error                → {code, message}
//   event: timeout              → достигнут max lifetime (30 мин)
//   event: shutdown             → плановый рестарт сервера, НЕ сетевой сбой
//
// Разбираются, но мобильным каналом СЕГОДНЯ не шлются — оставлены, потому что стоят дешевле
// молчаливого пропуска, если появятся:
//   event: escalation           → у канала эскалация в инбокс выключена (`escalateToInbox`
//                                 в capabilities = false), флаг «нужен человек» ставится
//                                 молча, и пользователю менеджера не обещают;
//   event: usage                → квота кабинетного хелп-виджета, мобильному не адресована.

import Foundation

/// Ответ менеджера, пришедший в открытый стрим.
public struct ManagerMessage: Equatable {
    public let messageId: Int
    public let text: String
    public let authorName: String?
}

public enum ChatStreamEvent: Equatable {
    case meta(conversationId: Int, mode: ChatMode)
    case contentDelta(String)
    case done
    case managerMessage(ManagerMessage)
    case escalation(triggered: Bool, reason: String)
    case forwardedToManager(mode: ChatMode)
    case heartbeat
    case serverError(code: String, message: String)
    case timeout
    case shutdown(reason: String)
    /// Событие, которого этот SDK ещё не знает. Не ошибка — сервер расширяем без ломки клиентов.
    case unknown(name: String)
}

extension ChatStreamEvent {

    /// Чистое отображение сырого SSE-события в типизированное. `nil` — событие без полезной
    /// нагрузки (пустой чанк, keep-alive), его нужно молча пропустить.
    static func from(_ sse: SSEEvent) -> ChatStreamEvent? {
        if sse.data == "[DONE]" { return .done }

        let json = Self.decodeObject(sse.data)

        switch sse.name {
        case "message":
            // Чанк генерации: {choices:[{delta:{content:"…"}}]}
            guard
                let choices = json?["choices"] as? [[String: Any]],
                let delta = choices.first?["delta"] as? [String: Any],
                let text = delta["content"] as? String,
                !text.isEmpty
            else { return nil }
            return .contentDelta(text)

        case "meta":
            let conversationId = (json?["conversationId"] as? Int) ?? -1
            let mode = ChatMode(rawValue: (json?["mode"] as? String) ?? "") ?? .ai
            return .meta(conversationId: conversationId, mode: mode)

        case "manager_message":
            guard let text = json?["text"] as? String else { return nil }
            return .managerMessage(
                ManagerMessage(
                    messageId: (json?["messageId"] as? Int) ?? 0,
                    text: text,
                    authorName: json?["authorName"] as? String
                )
            )

        case "escalation":
            return .escalation(
                triggered: (json?["triggered"] as? Bool) ?? true,
                reason: (json?["reason"] as? String) ?? "unknown"
            )

        case "forwarded_to_manager":
            let mode = ChatMode(rawValue: (json?["mode"] as? String) ?? "") ?? .pendingEscalation
            return .forwardedToManager(mode: mode)

        case "heartbeat":
            return .heartbeat

        case "usage":
            // Квота кабинетного хелп-виджета: мобильному клиенту не адресована.
            return .unknown(name: "usage")

        case "error":
            return .serverError(
                code: (json?["code"] as? String) ?? "server_error",
                message: (json?["message"] as? String) ?? "Server error"
            )

        case "timeout":
            return .timeout

        case "shutdown":
            return .shutdown(reason: (json?["reason"] as? String) ?? "server_restart")

        default:
            return .unknown(name: sse.name)
        }
    }

    private static func decodeObject(_ raw: String) -> [String: Any]? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
