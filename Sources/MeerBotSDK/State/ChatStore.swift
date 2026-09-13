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
    /// id строки на сервере — ключ слияния при догоне ленты.
    ///
    /// Отдельно от `id`: тот обязан быть стабильным для SwiftUI с первого кадра, то есть
    /// существовать ещё до отправки (оптимистичное сообщение пользователя). `nil` — строка
    /// пока живёт только на устройстве.
    public var serverId: Int?
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
        serverId: Int? = nil,
        role: String,
        author: String? = nil,
        authorName: String? = nil,
        content: String,
        streaming: Bool = false,
        failed: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.serverId = serverId
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
    /// Наибольший серверный id в ленте — курсор догона (`GET /mobile/messages?since=`).
    @Published public private(set) var lastServerMessageId: Int = 0

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

    /// Дописать кусок потока. Пробелы В НАЧАЛЕ ответа отбрасываются, пока текст пуст.
    ///
    /// Модель начинает ответ с перевода строки чаще, чем кажется (стабильно — на ответе про
    /// передачу менеджеру). Сервер такой ответ хранит уже подрезанным, поэтому лишний перенос
    /// жил только на устройстве: пузырь начинался с пустой строки, а догон ленты не узнавал в
    /// нём свою же строку и клал серверную копию рядом — сообщение двоилось.
    public func updateAssistantContent(id: String, delta: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[idx].content.isEmpty {
            messages[idx].content += String(delta.drop(while: { $0.isWhitespace }))
        } else {
            messages[idx].content += delta
        }
    }

    /// Ответ дописан: хвостовые пробелы убираем — на сервере строка хранится без них.
    public func finalizeAssistant(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].streaming = false
        while let last = messages[idx].content.last, last.isWhitespace {
            messages[idx].content.removeLast()
        }
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

    /// Заменить всю ленту.
    ///
    /// ⚠️ Стирает и неподтверждённые сообщения (отправляемое, недоставленное). SDK сам этот
    /// метод не зовёт: история вливается через `mergeServerMessages`, иначе ответ истории,
    /// пришедший после отправки, убирал бы отправленное сообщение с экрана.
    public func replaceAll(_ items: [ChatMessage]) {
        messages = items
        bumpCursor(items)
    }

    /// Влить серверную страницу в ленту — и догон `since`, и полную историю. Идемпотентно
    /// по `serverId`; неподтверждённые локальные сообщения не пропадают никогда.
    ///
    /// Два прохода, и порядок между ними важен.
    ///
    /// Проход 1, от новых строк страницы к старым — узнать своё:
    ///   1. `serverId` уже в ленте — пропускаем (страница пришла повторно, это норма догона);
    ///   2. есть локальный двойник (тот же `role` и текст, ещё без серверного id) — ПРОМОУТИМ
    ///      его, а не добавляем второй: иначе своё же сообщение пользователь увидит дважды.
    ///      Идём от новых к старым, чтобы эхо забрала самая новая строка с этим текстом, а не
    ///      вчерашнее «ок» из полной истории. Стримящийся пузырь не промоутим: он ещё
    ///      дописывается, и серверная строка с тем же текстом — не его окончательная версия.
    ///
    /// Проход 2, по порядку страницы — вставить остальное на своё место (см. `insertionIndex`),
    /// а не в конец: стартовая история, пришедшая после отправки, старше отправленного
    /// сообщения и должна встать над ним.
    ///
    /// Курсор двигается ВСЕГДА, даже если вся страница пропущена: иначе следующий догон
    /// запросил бы те же строки и цикл никогда бы не сдвинулся.
    ///
    /// - Returns: сколько сообщений реально появилось в ленте.
    @discardableResult
    public func mergeServerMessages(_ items: [ChatMessage]) -> Int {
        var recognized = Set<Int>()
        for (index, item) in items.enumerated().reversed() {
            if let sid = item.serverId, messages.contains(where: { $0.serverId == sid }) {
                recognized.insert(index)
                continue
            }
            // Сравнение по ПОДРЕЗАННОМУ тексту: сервер хранит ответ без крайних пробелов, а в
            // потоке они приходят (первым чанком часто идёт перевод строки). Точное равенство
            // роняло слияние в дубль ровно на таких ответах.
            let itemKey = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let localIdx = messages.lastIndex(where: {
                $0.serverId == nil && !$0.streaming && $0.role == item.role
                    && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == itemKey
            }) {
                messages[localIdx].serverId = item.serverId
                messages[localIdx].failed = false
                recognized.insert(index)
            }
        }

        var added = 0
        for (index, item) in items.enumerated() where !recognized.contains(index) {
            // Одна и та же строка дважды в странице.
            if let sid = item.serverId, messages.contains(where: { $0.serverId == sid }) { continue }
            messages.insert(item, at: insertionIndex(for: item))
            added += 1
        }
        bumpCursor(items)
        return added
    }

    /// Место новой серверной строки — сразу после последней строки ленты, которая раньше неё.
    ///
    /// Между серверными строками порядок задаёт `serverId` (он растёт на сервере). С
    /// неподтверждёнными сравнивать можно только время: серверный `createdAt` против часов
    /// устройства. Расхождение часов на секунды может переставить соседей — ответ менеджера,
    /// пришедший в те же секунды, что и недоставленное сообщение, — но ничего не теряет и не
    /// двоит. Главный случай (стартовая история старше отправки на минуты и дни) оно не задевает.
    private func insertionIndex(for item: ChatMessage) -> Int {
        let predecessor = messages.lastIndex { existing in
            if let existingId = existing.serverId, let itemId = item.serverId {
                return existingId < itemId
            }
            return existing.timestamp <= item.timestamp
        }
        return predecessor.map { $0 + 1 } ?? 0
    }

    /// Курсор только растёт: страница старее текущего значения не имеет права его откатить.
    private func bumpCursor(_ items: [ChatMessage]) {
        let maxId = items.compactMap(\.serverId).max() ?? 0
        if maxId > lastServerMessageId { lastServerMessageId = maxId }
    }

    /// Убрать пустой стриминговый плейсхолдер (ответ так и не начался).
    public func dropEmptyPlaceholder(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[idx].content.isEmpty { messages.remove(at: idx) }
    }

    public func resetForLogout() {
        resetForIdentityChange()
        greeting = nil
    }

    /// Сменился пользователь (выход или другой вход): лента, режим, черновик и курсор
    /// прежнего человека не должны пережить смену. Приветствие остаётся — его задаёт хост,
    /// и к пользователю оно не относится.
    func resetForIdentityChange() {
        messages.removeAll()
        mode = .ai
        operatorTyping = nil
        draft = ""
        sending = false
        connectionError = nil
        lastServerMessageId = 0
    }
}
