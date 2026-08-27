// MeerBot iOS SDK — связка «сеть ↔ состояние экрана».
//
// Здесь живут все решения о поведении на границе сети: что делать при обрыве, когда
// догонять историю, что показывать пользователю. ChatView остаётся тонким.

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

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
    private var pollTask: Task<Void, Never>?
    /// Экран чата на виду. Догон крутится ТОЛЬКО когда `screenVisible && isReady`.
    private var screenVisible = false
    private var lifecycleSubscriptions = Set<AnyCancellable>()

    /// Периоды догона — те же, что у веб-виджета. `var` ради тестов: они ужимают их до
    /// миллисекунд, иначе проверка «ответ менеджера доехал» ждала бы шесть секунд.
    static var managerPollInterval: TimeInterval = 6
    static var idlePollInterval: TimeInterval = 12
    /// Потолок страниц за один догон: сервер отдаёт `hasMore`, но цикл не имеет права стать
    /// бесконечным — при расхождении курсора он выжег бы батарею молча.
    private static let maxCatchUpPages = 5

    public init(client: APIClient) {
        self.client = client
        observeAppLifecycle()
    }

    /// Возврат приложения из фона.
    ///
    /// Подписка живёт в КОНТРОЛЛЕРЕ, а не во вью, по двум причинам. Первая: `chatController()`
    /// — задокументированная точка интеграции для хостов, которые рисуют свой UI, и поведение
    /// SDK не имеет права зависеть от того, наш ли экран на виду. Вторая: `swift test` идёт на
    /// macOS, где UIKit нет, а `scenePhase` из XCTest не подделать — метод ниже тест зовёт
    /// напрямую.
    private func observeAppLifecycle() {
        #if canImport(UIKit)
        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.onEnterForeground() }
            }
            .store(in: &lifecycleSubscriptions)
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.onEnterBackground() }
            }
            .store(in: &lifecycleSubscriptions)
        #endif
    }

    /// Приложение вернулось на передний план: догоняем немедленно, не дожидаясь тика.
    func onEnterForeground() {
        guard screenVisible, isReady else { return }
        Task { [weak self] in await self?.catchUp(silent: true) }
        startPolling()
    }

    /// Ушли в фон: опрос останавливаем — в фоне он всё равно не даёт ничего, кроме трафика.
    func onEnterBackground() {
        stopPolling()
    }

    /// Зарегистрировать устройство и подтянуть историю треда.
    public func start() {
        screenVisible = true
        guard startTask == nil else { return }

        // Сессия уже поднята: контроллер живёт в синглтоне SDK и переживает закрытие экрана.
        // Второй handshake не нужен (каждая регистрация — ещё один jti в Redis-allowlist и
        // upsert устройства), НО пока экран был закрыт, менеджер мог ответить. Раньше здесь
        // стоял молчаливый выход, и повторное открытие чата не перечитывало ленту вовсе.
        if isReady {
            Task { [weak self] in await self?.catchUp(silent: true) }
            startPolling()
            return
        }
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
                self.startPolling()
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
        Task { [weak self] in await self?.catchUp(silent: false) }
    }

    public func stop() {
        screenVisible = false
        stopPolling()
        streamTask?.cancel()
        streamTask = nil
        startTask?.cancel()
        startTask = nil
        store.setSending(false)
        // `isReady` СОЗНАТЕЛЬНО не сбрасываем: сессия остаётся живой, и следующее открытие
        // экрана обойдётся догоном вместо новой регистрации устройства.
    }

    // MARK: - Догон ленты

    /// Пока экран открыт, лента подтягивается сама.
    ///
    /// Это ЕДИНСТВЕННЫЙ надёжный канал «менеджер ответил → пользователь увидел»: поток
    /// живёт только на время ответа бота, а пуш зависит от бэкенда интегратора. Период
    /// пересчитывается на каждом витке, поэтому переход диалога к человеку ускоряет догон
    /// со следующего тика, без пересоздания задачи.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await MainActor.run {
                    self.store.mode == .human || self.store.mode == .pendingEscalation
                        ? Self.managerPollInterval
                        : Self.idlePollInterval
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self.catchUp(silent: true)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Подтянуть всё, что появилось после нашего курсора.
    ///
    /// `silent` — фоновый тик: его ошибки НЕ красят экран. Оборванная сеть у человека,
    /// который просто смотрит на переписку, не повод показывать ему «нет связи»; настоящую
    /// ошибку он и так увидит при отправке.
    ///
    /// Во время отправки догон не идёт: серверная страница принесла бы половину ещё
    /// стримящегося ответа и подралась бы с плейсхолдером.
    private func catchUp(silent: Bool) async {
        guard isReady, !store.sending, !Task.isCancelled else { return }

        do {
            for _ in 0..<Self.maxCatchUpPages {
                // Отмена проверяется ПЕРЕД каждой страницей: закрытый экран не должен
                // дочитывать длинную ленту. Уже отправленный запрос при этом долетит —
                // оборвать его на полпути нечем, да и незачем: ответ просто отбрасывается.
                if Task.isCancelled { return }
                let cursor = store.lastServerMessageId
                let page = try await client.history(since: cursor > 0 ? cursor : nil, limit: 50)
                store.setMode(page.mode)
                store.mergeServerMessages(Self.map(page.messages))
                if !page.hasMore { break }
            }
            // Баннер снимаем только если повторять нечего: иначе с экрана исчезла бы кнопка
            // «Повторить» вместе с сообщением о том, почему она там.
            if retryableText == nil { store.setError(nil) }
        } catch {
            guard !silent else { return }
            store.setError(Self.message(for: error))
        }
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
                // Разовый догон сразу после потока: он проставляет серверные id только что
                // отправленному сообщению и ответу. Без него первый же тик поллинга принёс бы
                // обе строки как «новые», и слияние держалось бы на совпадении текста.
                await self.catchUp(silent: true)
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
                serverId: item.id,
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
