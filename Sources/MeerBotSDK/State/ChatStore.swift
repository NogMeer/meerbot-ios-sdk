// MeerBot iOS SDK — состояние экрана чата.
// ObservableObject с сообщениями, режимом разговора, индикатором печати.
// Контракт совпадает с Kotlin ChatViewModel и RN reducer.

import Foundation
import Combine

public enum ChatMode: String, Codable {
    case ai
    case pendingEscalation = "pending_escalation"
    case human
    case closed
}

public struct ChatMessage: Identifiable, Equatable {
    public let id: String
    public let role: String          // "user" | "assistant" | "system"
    public let author: String?       // "ai" | "manager" | nil для system
    public let authorName: String?
    public var content: String
    public var streaming: Bool
    /// Сообщение не доставлено (обрыв сети при отправке) — UI показывает возможность повтора.
    public var failed: Bool
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: String,
        author: String? = nil,
        authorName: String? = nil,
        content: String,
        streaming: Bool = false,
        failed: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.author = author
        self.authorName = authorName
        self.content = content
        self.streaming = streaming
        self.failed = failed
        self.timestamp = timestamp
    }
}

@MainActor
public final class ChatStore: ObservableObject {

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var mode: ChatMode = .ai
    @Published public private(set) var operatorTyping: String? = nil
    @Published public private(set) var draft: String = ""
    @Published public private(set) var sending: Bool = false
    @Published public private(set) var connectionError: String? = nil
    /// Приветствие канала из handshake — показывается вместо дефолтной пустой заглушки.
    @Published public private(set) var greeting: String? = nil

    public init() {}

    public func setDraft(_ text: String) { draft = text }

    public func clearDraft() { draft = "" }

    public func setMode(_ newMode: ChatMode) { mode = newMode }

    public func setOperatorTyping(_ name: String?) { operatorTyping = name }

    public func setError(_ err: String?) { connectionError = err }

    public func setSending(_ value: Bool) { sending = value }

    /// Приветствие над пустой лентой.
    ///
    /// У мобильного канала СЕРВЕРНОГО источника нет: `ClientMobileApp` не хранит ни названия
    /// чата, ни приветствия (в отличие от веб-виджета, который отдавал их в handshake).
    /// Поэтому значение задаёт хост-приложение; не задал — `ChatView` покажет свой дефолт.
    public func setGreeting(_ text: String?) { greeting = text }

    @discardableResult
    public func appendUserMessage(_ content: String) -> ChatMessage {
        let msg = ChatMessage(role: "user", content: content)
        messages.append(msg)
        return msg
    }

    @discardableResult
    public func appendAssistantPlaceholder() -> ChatMessage {
        let msg = ChatMessage(role: "assistant", author: "ai", content: "", streaming: true)
        messages.append(msg)
        return msg
    }

    public func updateAssistantContent(id: String, delta: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content += delta
    }

    public func finalizeAssistant(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].streaming = false
    }

    public func appendOperatorMessage(content: String, authorName: String?) {
        messages.append(
            ChatMessage(
                role: "assistant",
                author: "manager",
                authorName: authorName,
                content: content
            )
        )
    }

    /// Пометить сообщение недоставленным (обрыв сети) либо снять пометку при повторе.
    public func setFailed(id: String, _ value: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].failed = value
    }

    public func removeMessage(id: String) {
        messages.removeAll { $0.id == id }
    }

    /// Заменить всю ленту (догон истории с сервера после обрыва — сервер источник правды).
    public func replaceAll(_ items: [ChatMessage]) {
        messages = items
    }

    /// Убрать пустой стриминговый плейсхолдер (ответ так и не начался).
    public func dropEmptyPlaceholder(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[idx].content.isEmpty { messages.remove(at: idx) }
    }

    public func resetForLogout() {
        messages.removeAll()
        mode = .ai
        operatorTyping = nil
        draft = ""
        sending = false
        connectionError = nil
        greeting = nil
    }
}
