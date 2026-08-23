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

    /// Идентификатор текущего диалога, или `nil` пока диалог не заведён (посетитель ещё не
    /// написал первым, и заводить тред не на что).
    ///
    /// Зачем публично: приложение хоста получает пуш «оператор ответил» СВОИМ бэкендом и
    /// должно уметь его подавить, если этот же диалог сейчас открыт на экране. Без этого
    /// значения приложение сравнить не с чем, и пользователь получает баннер о сообщении,
    /// которое видит прямо перед собой.
    ///
    /// ⚠️ Значение НЕПРОЗРАЧНО и действительно только в паре с каналом, которым работает
    /// SDK: у каждого канала своя последовательность id, и на бэкенде они пересекаются.
    /// Хранить его как «вечный» ключ пользователя нельзя — для адресации на своей стороне
    /// используйте идентификатор, который передали в identity-токене.
    @Published public private(set) var conversationId: Int?

    private var streamTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    public init(client: APIClient) {
        self.client = client
    }

    /// Зарегистрировать устройство и подтянуть историю треда.
    public func start() {
        // Повторный onAppear не должен выписывать новый JWT: каждая регистрация — это ещё
        // один jti в Redis-allowlist и upsert устройства на сервере.
        guard startTask == nil, !isReady else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.openSession()
                self.store.setError(nil)
                // История тянется ВСЕГДА: тред мобильного канала ключуется на устройстве, и
                // регистрация про существование диалога ничего не сообщает. Пустая лента —
                // штатный ответ, а не ошибка. Оттуда же приходит режим: кто отвечает
                // пользователю (`ai` | `human`), знает только серверная строка диалога.
                try? await self.loadHistory()
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

    /// Открыть диалог по deep link из пуша.
    ///
    /// У мобильного канала тред один и ключуется на устройстве, поэтому «открыть другой
    /// диалог» здесь означает «подтянуть свежую ленту»: id из пуша только запоминается —
    /// чтобы приложение могло сверять его с открытым экраном — и в запрос не уходит.
    public func openConversation(id: Int) {
        Task { [weak self] in
            guard let self else { return }
            await self.client.setConversationId(id)
            self.conversationId = id
            do {
                try await self.loadHistory()
                self.store.setError(nil)
            } catch {
                self.store.setError(Self.message(for: error))
            }
        }
    }

    /// Привести ленту к серверной, не открывая новый диалог и не перерегистрируя устройство.
    ///
    /// Когда звать: приложение вернулось на передний план либо его бэкенд получил вебхук
    /// `manager_reply` и разбудил приложение пушем. Своей отправки пушей у платформы нет —
    /// ответ менеджера уходит вебхуком на бэкенд интегратора, и он же адресует пуш.
    ///
    /// Отличие от `openConversation(id:)`: тот ПЕРЕКЛЮЧАЕТ тред по id из пуша, этот просто
    /// перечитывает текущий. Паритет с Android (`MeerBot.refresh()`).
    public func refresh() {
        Task { [weak self] in
            guard let self else { return }
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
        case let .meta(id, mode):
            // Первое сообщение в новом треде: диалог заводит сервер и сообщает его id
            // именно здесь. До этого события `conversationId` пуст — это не ошибка.
            // `-1` парсер отдаёт, когда поля в событии не было вовсе (см. ChatStreamEvent).
            if id > 0 { conversationId = id }
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
    ///
    /// Режим применяется ДАЖЕ при пустой ленте: «диалог у менеджера» — это состояние треда,
    /// а не свойство сообщений, и пропусти мы его, экран предлагал бы писать боту, который
    /// в этом режиме молчит.
    private func loadHistory() async throws {
        let page = try await client.history()
        store.setMode(page.mode)
        let items = Self.map(page.messages)
        guard !items.isEmpty else { return }
        store.replaceAll(items)
    }

    /// Полный тред диалога с сервера (не инкремент — иначе замена ленты обрезала бы её
    /// до пары последних сообщений).
    private func fetchHistory() async throws -> [ChatMessage] {
        Self.map(try await client.history().messages)
    }

    /// Автор берётся из ответа сервера, а не выводится из роли.
    ///
    /// Раньше здесь стояло `role == "assistant" ? "ai"`, и ответ живого менеджера,
    /// прочитанный из истории, подписывался ботом: в потоке автор приходит кадром
    /// `operator_message`, но после перезапуска приложения лента перечитывается отсюда.
    /// То есть подпись менеджера жила ровно до сворачивания приложения — в сценарии
    /// «менеджер ответил → пуш → пользователь вернулся» её не было никогда.
    ///
    /// `authorKind` отсутствует у старых сборок платформы → фолбэк на прежнее поведение.
    private static func map(_ items: [HistoryMessage]) -> [ChatMessage] {
        items.map { item in
            let isManager = item.authorKind == "manager"
            return ChatMessage(
                id: "srv-\(item.id)",
                role: item.role,
                author: item.role == "assistant" ? (isManager ? "manager" : "ai") : nil,
                authorName: isManager ? item.authorName : nil,
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
