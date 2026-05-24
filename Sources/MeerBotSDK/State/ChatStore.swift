// MeerBot iOS SDK — Phase 5.b: state machine для ChatView.
// ObservableObject c сообщениями, режимом разговора, индикатором печати.
// Идентичный контракт у Kotlin ChatViewModel и RN reducer.

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
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: String,
        author: String? = nil,
        authorName: String? = nil,
        content: String,
        streaming: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.author = author
        self.authorName = authorName
        self.content = content
        self.streaming = streaming
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

    public init() {}

    public func setDraft(_ text: String) { draft = text }

    public func clearDraft() { draft = "" }

    public func setMode(_ newMode: ChatMode) { mode = newMode }

    public func setOperatorTyping(_ name: String?) { operatorTyping = name }

    public func setError(_ err: String?) { connectionError = err }

    public func setSending(_ value: Bool) { sending = value }

    public func appendUserMessage(_ content: String) -> ChatMessage {
        let msg = ChatMessage(role: "user", content: content)
        messages.append(msg)
        return msg
    }

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

    public func resetForLogout() {
        messages.removeAll()
        mode = .ai
        operatorTyping = nil
        draft = ""
        sending = false
        connectionError = nil
    }
}
