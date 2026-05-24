// MeerBot iOS SDK — Phase 5.b: основной экран чата (SwiftUI).
//
// Контракт идентичен Android Compose ChatScreen и RN ChatScreen.

import SwiftUI

public struct ChatView: View {

    @StateObject private var store = ChatStore()
    @Environment(\.dismiss) private var dismiss

    private let title: String
    private let primaryColor: Color
    private let onClose: (() -> Void)?

    public init(
        title: String = "Поддержка",
        primaryColor: Color = .blue,
        onClose: (() -> Void)? = nil
    ) {
        self.title = title
        self.primaryColor = primaryColor
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ChatHeader(
                title: title,
                primaryColor: primaryColor,
                onClose: {
                    onClose?()
                    dismiss()
                }
            )
            Divider()
            MessagesList(store: store)
            if let typing = store.operatorTyping {
                HStack(spacing: 8) {
                    TypingIndicator()
                    Text("\(typing) печатает…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            if let err = store.connectionError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
            }
            ChatInput(
                store: store,
                primaryColor: primaryColor,
                onSend: { text in
                    Task { await sendMessage(text) }
                }
            )
        }
        .background(Color(.systemBackground))
        .accentColor(primaryColor)
    }

    private func sendMessage(_ text: String) async {
        await MainActor.run {
            _ = store.appendUserMessage(text)
            store.clearDraft()
            store.setSending(true)
        }
        // TODO Phase 5.b polish: реальный вызов APIClient.openChatStream через MeerBot.shared
        // Здесь — placeholder для демонстрации UI. Реальная интеграция через MeerBot.shared
        // выполняется в MeerBotSDK.swift configure() → создание APIClient instance.
        let placeholderId = await MainActor.run { store.appendAssistantPlaceholder() }.id
        try? await Task.sleep(nanoseconds: 600_000_000)
        await MainActor.run {
            store.updateAssistantContent(id: placeholderId, delta: "Это демо-ответ. Реальная интеграция через MeerBot.shared.configure().")
            store.finalizeAssistant(id: placeholderId)
            store.setSending(false)
        }
    }
}

private struct ChatHeader: View {
    let title: String
    let primaryColor: Color
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Закрыть чат")
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

struct MessagesList: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.messages.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("Привет! Чем могу помочь?")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(store.messages) { msg in
                            MessageBubbleView(message: msg)
                                .id(msg.id)
                        }
                    }
                }
            }
            .onChange(of: store.messages.count) { _ in
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

struct TypingIndicator: View {
    @State private var bounce = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(bounce ? 1.0 : 0.6)
                    .animation(
                        Animation.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                        value: bounce
                    )
            }
        }
        .onAppear { bounce = true }
    }
}

struct ChatInput: View {
    @ObservedObject var store: ChatStore
    let primaryColor: Color
    let onSend: (String) -> Void

    @State private var localDraft: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Сообщение…", text: $localDraft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(store.mode == .closed)
            Button(action: {
                let trimmed = localDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !store.sending, store.mode != .closed else { return }
                localDraft = ""
                onSend(trimmed)
            }) {
                Image(systemName: "paperplane.fill")
                    .padding(8)
                    .background(primaryColor)
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .disabled(localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.sending)
            .accessibilityLabel("Отправить")
        }
        .padding(8)
        .background(Color(.systemBackground))
    }
}
