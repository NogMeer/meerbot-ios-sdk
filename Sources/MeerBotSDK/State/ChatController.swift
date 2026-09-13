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
    /// Растёт при смене identity. Задачи, начатые до неё, сверяют значение после каждого
    /// `await`: отмена не останавливает уже отправленный запрос, и без сверки его ответ —
    /// страница ПРЕЖНЕГО пользователя — лёг бы в только что очищенную ленту.
    private var identityEpoch = 0
    /// Сколько смен identity начато (`beginIdentityChange`) и ещё не применено к `APIClient`.
    ///
    /// Между очисткой ленты и применением новой identity к клиенту есть `await`. Отправка,
    /// начатая в это окно, ушла бы с ПРЕЖНЕЙ identity (или зарегистрировалась бы уже с новой
    /// и попала в новый тред) — а сброс, пришедший следом, стёр бы её из ленты. Поэтому пока
    /// счётчик не ноль, сеть не трогаем: отправка ждёт в `queuedSend`, старт — в `finish`.
    private var pendingIdentityChanges = 0
    /// Сообщение, отправленное, пока применялась смена identity. Уходит сразу после неё.
    private var queuedSend: (text: String, userMessageId: String)?
    /// Фоновый догон остановлен: сессию не восстановила даже перерегистрация (`device_*`,
    /// `jwt_*` после повтора). Крутить его дальше — две регистрации и две истории каждые
    /// 12 секунд без шанса на успех. Снимается явным действием: показ экрана, отправка,
    /// `refresh()`.
    private var catchUpSuspended = false
    /// Номер текущей отправки — чтобы завершившаяся задача не обнулила ссылку на следующую.
    private var streamRunId = 0
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
        // Возврат из фона — не действие пользователя в чате: остановленный догон не будим.
        guard screenVisible, isReady, !catchUpSuspended else { return }
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
        // Показ экрана — явное действие: даём догону ещё одну попытку.
        catchUpSuspended = false
        // Сессия поднимется, когда смена identity дойдёт до клиента (`finishIdentityChange`):
        // сейчас регистрация ушла бы с прежней.
        guard pendingIdentityChanges == 0 else { return }
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
        let epoch = identityEpoch
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.openSession()
                // Identity сменилась: сброс уже запустил свою попытку, и `startTask` теперь
                // её — состояние этой, устаревшей, никуда не применяется.
                guard self.identityEpoch == epoch else { return }
                self.store.setError(nil)
                // История тянется ВСЕГДА: тред мобильного канала ключуется на устройстве, и
                // регистрация про существование диалога ничего не сообщает. Пустая лента —
                // штатный ответ, а не ошибка. Оттуда же приходит режим: кто отвечает
                // пользователю (`ai` | `human`), знает только серверная строка диалога.
                try? await self.loadHistory()
                guard self.identityEpoch == epoch else { return }
                self.isReady = true
                self.startPolling()
            } catch {
                guard self.identityEpoch == epoch else { return }
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
    ///
    /// Повторяется СТРОКА ленты, помеченная недоставленной, и её же текст. Нет такой строки —
    /// повторять нечего: пометку снимает только слияние, узнавшее сообщение на сервере. Раньше
    /// здесь стоял запасной `send(text)`, и «Повторить» после такого слияния отправлял уже
    /// доставленное сообщение второй раз — с дублем в треде и вторым платным ответом модели.
    public func retry() {
        guard retryableText != nil else { return }
        retryableText = nil
        guard let failed = store.messages.last(where: { $0.failed && $0.role == "user" }) else { return }
        store.setFailed(id: failed.id, false)
        run(text: failed.content, userMessageId: failed.id)
    }

    /// Открыть диалог по deep link из пуша.
    ///
    /// У мобильного канала тред один и ключуется на устройстве, поэтому «открыть другой
    /// диалог» здесь означает «подтянуть свежую ленту»: id из пуша только запоминается —
    /// чтобы приложение могло сверять его с открытым экраном — и в запрос не уходит.
    public func openConversation(id: Int) {
        // Пуш пришёл посреди смены identity — он адресован прежнему человеку. Лента нового
        // поднимется сама, когда смена применится.
        guard pendingIdentityChanges == 0 else { return }
        // Эпоха — на момент ВЫЗОВА: взятая внутри задачи, она оказалась бы уже новой, и id
        // диалога прежнего пользователя лёг бы в сессию следующего.
        let epoch = identityEpoch
        Task { [weak self] in
            guard let self else { return }
            guard self.identityEpoch == epoch else { return }
            await self.client.setConversationId(id)
            guard self.identityEpoch == epoch else { return }
            self.conversationId = id
            do {
                try await self.loadHistory()
                guard self.identityEpoch == epoch else { return }
                self.store.setError(nil)
            } catch {
                guard self.identityEpoch == epoch else { return }
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
    /// Отличие от `openConversation(id:)`: тот запоминает id из пуша (чтобы хост мог сверить
    /// его с открытым экраном) и перечитывает ленту целиком, этот догоняет текущую по курсору
    /// и id не трогает. Тред у канала один, поэтому ни тот, ни другой его не переключает.
    /// Паритет с Android (`MeerBot.refresh()`).
    public func refresh() {
        catchUpSuspended = false
        Task { [weak self] in
            guard let self else { return }
            await self.catchUp(silent: false)
            // Догон удался — возвращаем фоновый опрос, если его останавливал отказ сессии.
            if self.screenVisible, self.isReady, !self.catchUpSuspended { self.startPolling() }
        }
    }

    public func stop() {
        screenVisible = false
        stopPolling()
        streamTask?.cancel()
        streamTask = nil
        startTask?.cancel()
        startTask = nil
        store.setSending(false)
        // Отправка ждала смены identity, а экран закрыли: уйти ей теперь не с чего. Молча
        // пропасть она не имеет права — остаётся в ленте недоставленной, с «Повторить».
        if let queued = queuedSend {
            queuedSend = nil
            store.setFailed(id: queued.userMessageId, true)
            retryableText = queued.text
        }
        // `isReady` СОЗНАТЕЛЬНО не сбрасываем: сессия остаётся живой, и следующее открытие
        // экрана обойдётся догоном вместо новой регистрации устройства.
    }

    /// Сменился пользователь (`MeerBot.identify`): переписка прежнего человека не должна
    /// остаться на экране. Задачи отменяются, лента чистится (приветствие хоста остаётся),
    /// сессия считается закрытой.
    ///
    /// Звать СИНХРОННО в момент смены, ДО применения identity к `APIClient`; после
    /// применения — `finishIdentityChange()`. Между ними контроллер в сеть не ходит.
    func beginIdentityChange() {
        pendingIdentityChanges += 1
        identityEpoch += 1
        stopPolling()
        streamTask?.cancel()
        streamTask = nil
        startTask?.cancel()
        startTask = nil
        // Сообщение, ждавшее ПРЕДЫДУЩУЮ смену (вторая смена пришла, пока первая применялась),
        // отбрасывается СОЗНАТЕЛЬНО, а не помечается недоставленным, как при `stop()`. Его
        // набрал человек, чья лента сейчас стирается: оставить строку с «Повторить» значит
        // показать его текст следующему и дать отправить в свой тред. Сообщить об отказе тоже
        // некому — прежнего пользователя на экране уже нет. Строку и `sending` снимает сброс
        // ленты ниже.
        queuedSend = nil
        store.resetForIdentityChange()
        isReady = false
        retryableText = nil
        conversationId = nil
        catchUpSuspended = false
    }

    /// Новая identity применена к `APIClient`. Открытый экран переподключается уже с ней,
    /// закрытый в сеть не ходит и поднимет сессию при следующем показе.
    func finishIdentityChange() {
        guard pendingIdentityChanges > 0 else { return }
        pendingIdentityChanges -= 1
        guard pendingIdentityChanges == 0 else { return }
        if screenVisible { start() }
        if let queued = queuedSend {
            queuedSend = nil
            run(text: queued.text, userMessageId: queued.userMessageId)
        }
    }

    /// Смена identity целиком — для случаев, когда новая identity уже применена к клиенту.
    func resetForIdentityChange() {
        beginIdentityChange()
        finishIdentityChange()
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
        guard isReady, !store.sending, !catchUpSuspended, !Task.isCancelled else { return }
        let epoch = identityEpoch

        do {
            for _ in 0..<Self.maxCatchUpPages {
                // Отмена проверяется ПЕРЕД каждой страницей: закрытый экран не должен
                // дочитывать длинную ленту. Уже отправленный запрос при этом долетит —
                // оборвать его на полпути нечем, да и незачем: ответ просто отбрасывается.
                if Task.isCancelled { return }
                let cursor = store.lastServerMessageId
                let page = try await client.history(since: cursor > 0 ? cursor : nil, limit: 50)
                guard identityEpoch == epoch else { return }
                store.setMode(page.mode)
                mergeServerPage(Self.map(page.messages))
                if !page.hasMore { break }
            }
            // Баннер снимаем только если повторять нечего: иначе с экрана исчезла бы кнопка
            // «Повторить» вместе с сообщением о том, почему она там.
            if retryableText == nil { store.setError(nil) }
        } catch {
            guard identityEpoch == epoch else { return }
            // Сессию не восстановила даже перерегистрация с повтором (они уже были внутри
            // `history`). Следующий тик кончится тем же — останавливаемся и говорим об этом
            // даже фоновому догону: иначе лента молча перестаёт обновляться.
            if Self.isSessionLost(error) {
                catchUpSuspended = true
                stopPolling()
                store.setError(Self.message(for: error))
                return
            }
            guard !silent else { return }
            store.setError(Self.message(for: error))
        }
    }

    /// 401, который клиент уже пытался вылечить перерегистрацией (см.
    /// `APIClient.isRecoverableBySession`), — до контроллера он доходит только после неудачи.
    private static func isSessionLost(_ error: Error) -> Bool {
        guard case let .http(status, code, _) = error as? MeerBotError else { return false }
        return APIClient.isRecoverableBySession(status: status, code: code)
    }

    // MARK: - Поток

    private func run(text: String, userMessageId: String) {
        if pendingIdentityChanges > 0 {
            // Сообщение остаётся в ленте и уйдёт, как только смена identity применится
            // (`finishIdentityChange`); `sending` не даёт отправить второе поверх.
            queuedSend = (text, userMessageId)
            store.setError(nil)
            store.setSending(true)
            return
        }
        streamTask?.cancel()
        store.setError(nil)
        store.setSending(true)
        let placeholder = store.appendAssistantPlaceholder()

        let epoch = identityEpoch
        streamRunId += 1
        let runId = streamRunId
        streamTask = Task { [weak self] in
            guard let self else { return }
            // Сервер закончил ответ сам (`[DONE]`, ошибка, таймаут, рестарт) — отличает
            // завершённый поток от оборванного отменой.
            var serverFinished = false
            do {
                for try await event in await self.client.sendMessage(text) {
                    // Смена identity отменяет задачу, но кадр, уже лежащий в буфере потока,
                    // мог бы дойти — в ленту нового пользователя.
                    guard self.identityEpoch == epoch else { return }
                    if self.handle(event, userMessageId: userMessageId, placeholderId: placeholder.id) {
                        serverFinished = true
                    }
                }
                guard self.identityEpoch == epoch else { return }
                // Отмена потребителем (`stop()` — экран закрыли) заканчивает `AsyncThrowingStream`
                // НЕ ошибкой, а обычным концом цикла. Без этой ветки она проходила как успех:
                // сообщение, чья регистрация ещё шла, пропадало без пометки, а в ленте
                // оставался недописанный пузырь.
                if Task.isCancelled, !serverFinished {
                    self.settleCancelledSend(text: text, userMessageId: userMessageId, placeholderId: placeholder.id)
                    if self.streamRunId == runId { self.streamTask = nil }
                    return
                }
                self.store.finalizeAssistant(id: placeholder.id)
                self.store.dropEmptyPlaceholder(id: placeholder.id)
                self.store.setSending(false)
                // Отправка прошла — сессия жива: снимаем остановку догона, если она была.
                if self.catchUpSuspended {
                    self.catchUpSuspended = false
                    if self.screenVisible, self.isReady { self.startPolling() }
                }
                // Разовый догон сразу после потока: он проставляет серверные id только что
                // отправленному сообщению и ответу. Без него первый же тик поллинга принёс бы
                // обе строки как «новые», и слияние держалось бы на совпадении текста.
                await self.catchUp(silent: true)
            } catch {
                guard self.identityEpoch == epoch else { return }
                await self.handleFailure(
                    error,
                    text: text,
                    userMessageId: userMessageId,
                    placeholderId: placeholder.id
                )
            }
            // Обнуляем ссылку, только если она всё ещё указывает на ЭТУ задачу: иначе
            // отправка, начатая следом, потеряла бы возможность быть отменённой. Сверка по
            // номеру, а не по самой задаче: захват изменяемой ссылки на задачу в её же
            // замыкании Swift 6 запрещает.
            if self.streamRunId == runId { self.streamTask = nil }
        }
    }

    /// - Returns: `true` — событие завершает ответ со стороны сервера.
    private func handle(_ event: ChatStreamEvent, userMessageId: String, placeholderId: String) -> Bool {
        switch event {
        case let .meta(id, mode):
            // Первое сообщение в новом треде: диалог заводит сервер и сообщает его id
            // именно здесь. До этого события `conversationId` пуст — это не ошибка.
            // `-1` парсер отдаёт, когда поля в событии не было вовсе (см. ChatStreamEvent).
            if id > 0 { conversationId = id }
            store.setMode(mode)
            return false

        case let .contentDelta(text):
            store.updateAssistantContent(id: placeholderId, delta: text)
            return false

        case .done:
            store.finalizeAssistant(id: placeholderId)
            store.dropEmptyPlaceholder(id: placeholderId)
            store.setSending(false)
            return true

        case let .managerMessage(message):
            store.appendOperatorMessage(content: message.text, authorName: message.authorName)
            store.setOperatorTyping(nil)
            return false

        case .escalation:
            store.setMode(.pendingEscalation)
            return false

        case let .forwardedToManager(mode):
            store.setMode(mode)
            return false

        case .heartbeat:
            // Живое соединение — снимаем баннер предыдущей ошибки.
            store.setError(nil)
            return false

        case let .serverError(code, message):
            store.finalizeAssistant(id: placeholderId)
            store.dropEmptyPlaceholder(id: placeholderId)
            store.setSending(false)
            store.setError(MeerBotError.stream(code: code, message: message).userMessage)
            return true

        case .timeout:
            store.finalizeAssistant(id: placeholderId)
            store.setSending(false)
            return true

        case .shutdown:
            // Плановый рестарт сервера — не сетевой сбой. Ответ уже могли дописать в БД.
            // История вливается, а не заменяет ленту, поэтому недописанный пузырь убираем
            // сами, если сервер ответ дописал. Смена identity между этими шагами безопасна:
            // `loadHistory` сверяет эпоху, а id сообщений прежней ленты в новой не найдутся.
            store.finalizeAssistant(id: placeholderId)
            store.setSending(false)
            Task {
                try? await self.loadHistory()
                _ = self.settleInterruptedReply(userMessageId: userMessageId, placeholderId: placeholderId)
            }
            return true

        case .unknown:
            return false
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
        // Отменили САМУ отправку (`stop()`, новая отправка): смену identity отсекла сверка
        // эпохи до вызова. Разбор — тот же, что у отмены, закончившей поток без ошибки.
        // `.cancelled` при живой задаче — это исчерпанные попытки регистрации: запрос не ушёл,
        // и он идёт по обычной ветке ниже — к «Повторить».
        if Task.isCancelled {
            settleCancelledSend(text: text, userMessageId: userMessageId, placeholderId: placeholderId)
            return
        }

        store.setSending(false)
        store.finalizeAssistant(id: placeholderId)
        store.dropEmptyPlaceholder(id: placeholderId)
        store.setError(Self.message(for: error))
        let epoch = identityEpoch

        // Диалог мог быть уже заведён, а ответ — дописан сервером, пока рвалось соединение.
        // Историю вливаем, а доставкой считаем только эхо ЭТОГО сообщения с ответом после
        // него. Раньше хватало «лента кончается ответом»: прошлый ответ бота выдавал
        // недошедшее сообщение за доставленное, замена ленты убирала его, и «Повторить» не было.
        if await client.conversationId != nil, let items = try? await fetchHistory() {
            guard identityEpoch == epoch else { return }
            mergeServerPage(items)
            if settleInterruptedReply(userMessageId: userMessageId, placeholderId: placeholderId) {
                return
            }
        }
        guard identityEpoch == epoch else { return }

        // Эхо сообщения уже в ленте (его принесла стартовая история или сверка выше), а
        // ответа ещё нет: сообщение ДОСТАВЛЕНО, ответ приедет догоном. «Повторить» здесь
        // отправил бы его второй раз — дубль в треде и второй платный ответ модели.
        if isDelivered(userMessageId) { return }

        store.setFailed(id: userMessageId, true)
        retryableText = text
    }

    /// Отправку отменили изнутри приложения — закрыли экран (`stop()`) или начали новую.
    ///
    /// Разбор тот же, что у сообщения, ждавшего смены identity при закрытии экрана
    /// (`stop()`): сообщение без серверного эха считается НЕДОСТАВЛЕННЫМ — дошёл ли запрос,
    /// не знает никто, а молча пропасть оно не имеет права. Если запрос всё же дошёл, догон
    /// при следующем показе экрана узнает эхо, снимет пометку и уберёт «Повторить»
    /// (`mergeServerPage`). Баннер не ставим: ошибки связи не было.
    ///
    /// Недописанный пузырь убирается: сервер на обрыв соединения прерывает генерацию, и
    /// обрывок окончательной версией не станет — что сервер сохранил, принесёт догон.
    private func settleCancelledSend(text: String, userMessageId: String, placeholderId: String) {
        store.setSending(false)
        if store.messages.first(where: { $0.id == placeholderId })?.serverId == nil {
            store.removeMessage(id: placeholderId)
        }
        guard !isDelivered(userMessageId) else { return }
        store.setFailed(id: userMessageId, true)
        retryableText = text
    }

    /// Сервер узнал в строке своё сообщение (слияние проставило ей серверный id).
    private func isDelivered(_ userMessageId: String) -> Bool {
        store.messages.first(where: { $0.id == userMessageId })?.serverId != nil
    }

    /// Влить серверную страницу и привести «Повторить» к ленте.
    ///
    /// Слияние снимает пометку «не доставлено» с сообщения, которое сервер всё-таки принял.
    /// `retryableText` при этом оставался, и кнопка вела в повтор уже доставленного. Теперь он
    /// следует за последней ещё недоставленной строкой, а если таких нет — снимается.
    private func mergeServerPage(_ items: [ChatMessage]) {
        store.mergeServerMessages(items)
        guard retryableText != nil else { return }
        retryableText = store.messages.last(where: { $0.failed && $0.role == "user" })?.content
    }

    /// Полная история треда, ВЛИТАЯ в ленту.
    ///
    /// Не замена: пользователь пишет, как только открылся экран, и ответ стартовой истории
    /// приходит уже после отправки. Замена убирала с экрана отправленное сообщение и
    /// стримящийся ответ — при том что сообщение могло уже дойти до сервера. Слияние
    /// сохраняет неподтверждённые строки, узнаёт эхо своих и ставит историю над ними.
    ///
    /// Режим применяется ДАЖЕ при пустой ленте: «диалог у менеджера» — это состояние треда,
    /// а не свойство сообщений, и пропусти мы его, экран предлагал бы писать боту, который
    /// в этом режиме молчит.
    private func loadHistory() async throws {
        let epoch = identityEpoch
        let page = try await client.history()
        guard identityEpoch == epoch else { return }
        store.setMode(page.mode)
        mergeServerPage(Self.map(page.messages))
    }

    /// Сервер дописал ответ на прерванную отправку: сообщение получило серверный id, и после
    /// него есть серверный ответ. Недописанный локальный пузырь тогда лишний — серверная
    /// версия ответа уже в ленте, и без удаления пользователь видел бы ответ дважды.
    ///
    /// Серверный id у сообщения — это эхо, которое слияние признало НОВЕЕ курсора на момент
    /// отправки (`ChatStore.canBeEcho`), поэтому вчерашняя строка с тем же текстом и ответ
    /// на неё доставкой здесь не посчитаются.
    ///
    /// Звать ПОСЛЕ слияния полной истории.
    private func settleInterruptedReply(userMessageId: String, placeholderId: String) -> Bool {
        let feed = store.messages
        guard
            let userServerId = feed.first(where: { $0.id == userMessageId })?.serverId,
            feed.contains(where: { $0.role == "assistant" && ($0.serverId ?? 0) > userServerId })
        else { return false }
        if feed.first(where: { $0.id == placeholderId })?.serverId == nil {
            store.removeMessage(id: placeholderId)
        }
        return true
    }

    /// Полный тред диалога с сервера (не инкремент: сверка «ответ дописан» смотрит на
    /// строки после сообщения, и обрезанная страница их бы не содержала).
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
        // До экрана `.cancelled` доходит только как несостоявшийся запрос (отмену самой
        // задачи экран не показывает), и «Отменено.» пользователю ничего не объясняет.
        if case .cancelled = error as? MeerBotError {
            return "Запрос не выполнен. Попробуйте ещё раз."
        }
        return (error as? MeerBotError)?.userMessage ?? MeerBotError
            .network(code: .unknown, message: error.localizedDescription).userMessage
    }
}
