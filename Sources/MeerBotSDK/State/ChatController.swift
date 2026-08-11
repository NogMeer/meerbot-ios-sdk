// MeerBot iOS SDK — связка «сеть ↔ состояние экрана».
//
// Здесь живут все решения о поведении на границе сети: что делать при обрыве, когда
// догонять историю, что показывать пользователю. ChatView остаётся тонким.

import Foundation
import Combine

@MainActor
public final class ChatController: ObservableObject {

    public let store = ChatStore()
    private let client: APIClient

    /// Handshake выполнен — можно отправлять.
    @Published public private(set) var isReady = false
    /// Текст, который не удалось отправить: UI показывает «Повторить».
    @Published public private(set) var retryableText: String?

    private var streamTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    public init(client: APIClient) {
        self.client = client
    }

    /// Открыть сессию и подтянуть историю прошлого диалога (если он восстановлен сервером).
    public func start() {
        // Повторный onAppear не должен выписывать новый JWT: каждый handshake — это ещё один
        // jti в Redis-allowlist и upsert визитора на сервере.
        guard startTask == nil, !isReady else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.client.openSession()
                self.store.setGreeting(session.greeting)
                self.store.setMode(session.mode)
                self.store.setError(nil)
                if session.conversationId != nil {
                    try? await self.loadHistory()
                }
                self.isReady = true
            } catch {
                self.isReady = false
                self.store.setError(Self.message(for: error))
            }
            self.startTask = nil
        }
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !store.sending, store.mode != .closed else { return }
        retryableText = nil
        let userMessage = store.appendUserMessage(trimmed)
        run(text: trimmed, userMessageId: userMessage.id)
    }

    /// Повторить последнюю неудачную отправку.
    public func retry() {
        guard let text = retryableText else { return }
        retryableText = nil
        // Прошлое сообщение осталось в ленте помеченным как недоставленное — переиспользуем его.
        if let failed = store.messages.last(where: { $0.failed && $0.role == "user" }) {
            store.setFailed(id: failed.id, false)
            run(text: text, userMessageId: failed.id)
        } else {
            send(text)
        }
    }

    /// Открыть конкретный диалог (deep link из пуша) и подтянуть его историю.
    public func openConversation(id: Int) {
        Task { [weak self] in
            guard let self else { return }
            await self.client.setConversationId(id)
            do {
                try await self.loadHistory()
                self.store.setError(nil)
            } catch {
                self.store.setError(Self.message(for: error))
            }
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        startTask?.cancel()
        startTask = nil
        store.setSending(false)
    }

    // MARK: - Поток

    private func run(text: String, userMessageId: String) {
        streamTask?.cancel()
        store.setError(nil)
        store.setSending(true)
        let placeholder = store.appendAssistantPlaceholder()

        var task: Task<Void, Never>?
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await self.client.sendMessage(text) {
                    self.handle(event, placeholderId: placeholder.id)
                }
                self.store.finalizeAssistant(id: placeholder.id)
                self.store.dropEmptyPlaceholder(id: placeholder.id)
                self.store.setSending(false)
            } catch {
                await self.handleFailure(
                    error,
                    text: text,
                    userMessageId: userMessageId,
                    placeholderId: placeholder.id
                )
            }
            // Обнуляем ссылку, только если она всё ещё указывает на ЭТУ задачу: иначе
            // отправка, начатая следом, потеряла бы возможность быть отменённой.
            if self.streamTask == task { self.streamTask = nil }
        }
        streamTask = task
    }

    private func handle(_ event: ChatStreamEvent, placeholderId: String) {
        switch event {
        case let .meta(_, mode):
            store.setMode(mode)

        case let .contentDelta(text):
            store.updateAssistantContent(id: placeholderId, delta: text)

        case .done:
            store.finalizeAssistant(id: placeholderId)
            store.dropEmptyPlaceholder(id: placeholderId)
            store.setSending(false)

        case let .managerMessage(message):
            store.appendOperatorMessage(content: message.text, authorName: message.authorName)
            store.setOperatorTyping(nil)

        case .escalation:
            store.setMode(.pendingEscalation)

        case let .forwardedToManager(mode):
            store.setMode(mode)

        case .heartbeat:
            // Живое соединение — снимаем баннер предыдущей ошибки.
            store.setError(nil)

        case let .serverError(code, message):
            store.finalizeAssistant(id: placeholderId)
            store.dropEmptyPlaceholder(id: placeholderId)
            store.setSending(false)
            store.setError(MeerBotError.stream(code: code, message: message).userMessage)

        case .timeout:
            store.finalizeAssistant(id: placeholderId)
            store.setSending(false)

        case .shutdown:
            // Плановый рестарт сервера — не сетевой сбой. Ответ уже могли дописать в БД.
            store.finalizeAssistant(id: placeholderId)
            store.setSending(false)
            Task { try? await self.loadHistory() }

        case .unknown:
            break
        }
    }

    /// Обрыв или ошибка транспорта. Частично полученный текст НЕ выбрасываем, состояние
    /// пытаемся привести к серверному: если диалог уже заведён — перечитываем ленту.
    private func handleFailure(
        _ error: Error,
        text: String,
        userMessageId: String,
        placeholderId: String
    ) async {
        store.setSending(false)
        store.finalizeAssistant(id: placeholderId)
        store.dropEmptyPlaceholder(id: placeholderId)

        if let meerBotError = error as? MeerBotError, case .cancelled = meerBotError { return }
        if error is CancellationError { return }

        store.setError(Self.message(for: error))

        // Диалог мог быть уже заведён, а ответ — дописан сервером, пока рвалось соединение.
        // Серверную ленту принимаем ТОЛЬКО если она заканчивается ответом: иначе замена
        // выбросила бы из UI недоставленное сообщение пользователя.
        if await client.conversationId != nil,
           let items = try? await fetchHistory(),
           items.last?.role == "assistant" {
            store.replaceAll(items)
            return
        }

        store.setFailed(id: userMessageId, true)
        retryableText = text
    }

    /// Догон истории: сервер — источник правды, локальную ленту заменяем целиком.
    private func loadHistory() async throws {
        let items = try await fetchHistory()
        guard !items.isEmpty else { return }
        store.replaceAll(items)
    }

    /// Полный тред диалога с сервера (не инкремент — иначе замена ленты обрезала бы её
    /// до пары последних сообщений).
    private func fetchHistory() async throws -> [ChatMessage] {
        try await client.history().map { item in
            ChatMessage(
                id: "srv-\(item.id)",
                role: item.role,
                author: item.role == "assistant" ? "ai" : nil,
                content: item.content,
                timestamp: item.createdAt ?? Date()
            )
        }
    }

    private static func message(for error: Error) -> String {
        (error as? MeerBotError)?.userMessage ?? MeerBotError
            .network(code: .unknown, message: error.localizedDescription).userMessage
    }
}
