// MeerBot iOS SDK — состояние экрана чата.
// ObservableObject с сообщениями, режимом разговора, индикатором печати.
// Контракт совпадает с Kotlin ChatViewModel и RN reducer.

import Foundation
import Combine

public enum ChatMode: String, Codable, Sendable {
    case ai
    case pendingEscalation = "pending_escalation"
    case human
    case closed
}

/// Вид вложения. Совпадает с `QuickReplyMediaKind` бэкенда (`image | video | audio |
/// document`) и с классификацией на Android. Клиент выводит его из mime САМ только для
/// оптимистичной плашки исходящего файла — окончательный вид приходит с сервера.
public enum AttachmentKind {
    /// Из mime-типа, как `classifyMediaKind` на бэкенде: всё, что не image/video/audio, —
    /// документ. Значение — строка (`ChatMessage`/`Attachment` держат его строкой ради
    /// паритета формата с сервером, где это тоже строка).
    public static func classify(_ mime: String) -> String {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return "image" }
        if m.hasPrefix("video/") { return "video" }
        if m.hasPrefix("audio/") { return "audio" }
        return "document"
    }
}

/// Вложение сообщения — как его отдаёт бэкенд (без `r2Key`). Раздача картинки:
/// `GET /api/v1/mobile/media/<messageId>/<mediaId>` с `Authorization: Bearer <JWT>`,
/// где `messageId` — серверный id несущего сообщения (`ChatMessage.serverId`).
///
/// `mediaId` пуст у ЛОКАЛЬНОГО превью (файл выбран, но ещё не загружен): такое вложение
/// рисуется плашкой, а не картинкой, пока догон истории не принесёт серверную версию.
public struct Attachment: Identifiable, Equatable, Sendable {
    /// Стабильный ключ для SwiftUI. У серверного вложения — это `mediaId`; у локального
    /// превью (mediaId пуст) — свой UUID, иначе два неотправленных файла схлопнулись бы в один.
    public let id: String
    public let mediaId: String
    /// `image | video | audio | document`.
    public let kind: String
    public let mime: String
    public let fileName: String?
    public let size: Int
    public let width: Int?
    public let height: Int?
    public let duration: Int?

    public init(
        mediaId: String,
        kind: String,
        mime: String,
        fileName: String?,
        size: Int,
        width: Int? = nil,
        height: Int? = nil,
        duration: Int? = nil,
        id: String? = nil
    ) {
        self.mediaId = mediaId
        self.id = id ?? (mediaId.isEmpty ? UUID().uuidString : mediaId)
        self.kind = kind
        self.mime = mime
        self.fileName = fileName
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
    }

    /// Разбор массива вложений из ответа сервера (история и `manager_message`). Запись без
    /// `mediaId` (строкой) пропускается: без него картинку не раздать. Форма и имена полей —
    /// `WidgetAttachmentDTO` бэкенда, паритет с Android.
    static func parse(_ raw: [[String: Any]]) -> [Attachment] {
        raw.compactMap { item in
            guard let mediaId = item["mediaId"] as? String, !mediaId.isEmpty else { return nil }
            return Attachment(
                mediaId: mediaId,
                kind: (item["kind"] as? String) ?? AttachmentKind.classify(item["mime"] as? String ?? ""),
                mime: (item["mime"] as? String) ?? "application/octet-stream",
                fileName: item["fileName"] as? String,
                size: (item["size"] as? Int) ?? 0,
                width: item["width"] as? Int,
                height: item["height"] as? Int,
                duration: item["duration"] as? Int
            )
        }
    }
}

/// Файл, выбранный пользователем и готовый к загрузке (`POST /mobile/upload`). Без UIKit —
/// чтобы `ChatController` компилировался на macOS-хосте CI; сам выбор файла живёт в
/// `AttachmentPicker` под `#if canImport(UIKit)`.
public struct OutgoingAttachment: Sendable, Equatable {
    public let data: Data
    public let fileName: String
    public let mime: String
    public var kind: String { AttachmentKind.classify(mime) }

    public init(data: Data, fileName: String, mime: String) {
        self.data = data
        self.fileName = fileName
        self.mime = mime
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
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
    /// Вложения сообщения. У исходящего — сперва локальные превью (mediaId пуст), затем
    /// серверные (их проставляет слияние истории). У входящего/менеджерского — серверные.
    public var attachments: [Attachment]

    public init(
        id: String = UUID().uuidString,
        serverId: Int? = nil,
        role: String,
        author: String? = nil,
        authorName: String? = nil,
        content: String,
        streaming: Bool = false,
        failed: Bool = false,
        timestamp: Date = Date(),
        attachments: [Attachment] = []
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
        self.attachments = attachments
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
    /// Выше загруженного есть более старые сообщения — экран подгружает их прокруткой вверх.
    @Published public private(set) var hasOlder: Bool = false
    /// Идёт подгрузка более старых сообщений.
    @Published public private(set) var loadingOlder: Bool = false
    /// Последняя подгрузка старых упала — экран показывает «Повторить», автоповтора нет.
    @Published public private(set) var olderFailed: Bool = false

    /// Курсор на момент появления локальной строки: её эхо на сервере обязано быть НОВЕЕ.
    ///
    /// Слияние узнаёт эхо по тексту, а текст повторяется («да», «ок»). Без этой границы
    /// вчерашнее «да» из стартовой истории забирало сегодняшнее неотправленное: строка
    /// получала чужой серверный id, вчерашняя пропадала из ленты, а сверка после обрыва
    /// видела «эхо и ответ после него» и объявляла недошедшее сообщение доставленным —
    /// без «Повторить». Всё, что на сервере не старше курсора, существовало до отправки.
    ///
    /// Не в `ChatMessage`: граница — знание этого экземпляра ленты, а не свойство сообщения,
    /// и публичная модель (с её `Equatable`) от неё меняться не должна.
    private var echoFloors: [String: Int] = [:]
    /// Расхождение часов устройства и сервера, которое терпит сверка по времени (когда
    /// курсора на момент отправки не было — история ещё не пришла).
    static let echoClockTolerance: TimeInterval = 5 * 60

    /// Локальные строки, про которые сервер сказал «записал» — по `clientMessageId`, а не по
    /// совпадению текста. Такое сопоставление точное, и догадки (`echoFloors`, часы, текст)
    /// к ним больше не применяются.
    private var idConfirmed: Set<String> = []

    /// Сервер понимает `clientMessageId` (прислал его в `meta` или отдал ключ в истории).
    ///
    /// Только поднимается: один ответ старого узла за балансировщиком не должен вернуть
    /// экран к сопоставлению по тексту, когда точное сопоставление уже работало.
    private(set) var clientIdsSupported: Bool = false

    public init() {}

    /// Сервер поддерживает идемпотентную отправку.
    func noteClientIdsSupported() { clientIdsSupported = true }

    /// Сервер подтвердил приём локальной строки: `clientMessageId` совпал, строка получила
    /// серверный id. Курсор НЕ двигаем — он курсор ленты, а не отправки; `failed` не трогаем:
    /// снимет его нормализация, когда станет видно, что за сообщением уже есть ответ.
    func confirmUserMessage(localId: String, serverId: Int) {
        guard let idx = messages.firstIndex(where: { $0.id == localId }) else { return }
        if messages[idx].serverId == nil { messages[idx].serverId = serverId }
        idConfirmed.insert(localId)
        echoFloors[localId] = nil
    }

    /// Строка подтверждена сервером по `clientMessageId`.
    func isIdConfirmed(_ localId: String) -> Bool { idConfirmed.contains(localId) }

    /// За сообщением на сервере уже что-то есть — значит, ответ либо пришёл, либо не придёт
    /// автоматически (диалог у человека), и повторять отправку нечего.
    func isSettled(_ localId: String) -> Bool {
        guard let message = messages.first(where: { $0.id == localId }) else { return false }
        if mode == .human || mode == .pendingEscalation { return true }
        guard let serverId = message.serverId else { return false }
        return messages.contains { ($0.serverId ?? 0) > serverId }
    }

    public func setDraft(_ text: String) { draft = text }

    public func clearDraft() { draft = "" }

    public func setMode(_ newMode: ChatMode) { mode = newMode }

    func setHasOlder(_ value: Bool) { hasOlder = value }

    func setLoadingOlder(_ loading: Bool, failed: Bool = false) {
        loadingOlder = loading
        olderFailed = failed
    }

    /// Самый старый серверный id в ленте — курсор `before` для подгрузки старых.
    var oldestServerMessageId: Int? { messages.compactMap(\.serverId).min() }

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
    public func appendUserMessage(_ content: String, attachments: [Attachment] = []) -> ChatMessage {
        appendLocal(ChatMessage(role: "user", content: content, attachments: attachments))
    }

    @discardableResult
    public func appendAssistantPlaceholder() -> ChatMessage {
        appendLocal(ChatMessage(role: "assistant", author: "ai", content: "", streaming: true))
    }

    private func appendLocal(_ msg: ChatMessage) -> ChatMessage {
        echoFloors[msg.id] = lastServerMessageId
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

    public func appendOperatorMessage(
        content: String,
        authorName: String?,
        serverId: Int? = nil,
        attachments: [Attachment] = []
    ) {
        // serverId проставляется, когда его знает поток (`manager_message.messageId`): по нему
        // догон истории узнаёт уже показанную строку и не кладёт её вторично (пропуск по
        // `serverId` в `mergeServerMessages`). Без него та же строка приезжала бы дублем.
        _ = appendLocal(
            ChatMessage(
                serverId: serverId,
                role: "assistant",
                author: "manager",
                authorName: authorName,
                content: content,
                attachments: attachments
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
        echoFloors[id] = nil
        idConfirmed.remove(id)
    }

    /// Заменить всю ленту.
    ///
    /// ⚠️ Стирает и неподтверждённые сообщения (отправляемое, недоставленное). SDK сам этот
    /// метод не зовёт: история вливается через `mergeServerMessages`, иначе ответ истории,
    /// пришедший после отправки, убирал бы отправленное сообщение с экрана.
    public func replaceAll(_ items: [ChatMessage]) {
        messages = items
        echoFloors.removeAll()
        idConfirmed.removeAll()
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
    ///      Двойником может быть только строка, которая на сервере НОВЕЕ локальной
    ///      (`canBeEcho`): вчерашнее «ок» из полной истории эхом сегодняшнего не бывает.
    ///      Идём от новых к старым, чтобы из подходящих эхо забрала самая новая. Стримящийся
    ///      пузырь не промоутим: он ещё дописывается, и серверная строка с тем же текстом —
    ///      не его окончательная версия.
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
        mergeServerMessages(items, clientIds: [:])
    }

    /// Тот же метод, но со связкой `serverId → clientMessageId` из ответа сервера.
    ///
    /// Сопоставление по id точное и идёт ПЕРЕД текстовым: строка со своим `clientMessageId`
    /// узнаётся вне зависимости от текста, курсора, часов и стриминга, а серверная строка с
    /// ЧУЖИМ id по тексту не сопоставляется никогда — иначе два человека, написавшие «да» в
    /// одном треде с одного устройства до и после входа, перепутались бы местами.
    @discardableResult
    func mergeServerMessages(_ items: [ChatMessage], clientIds: [Int: String]) -> Int {
        var recognized = Set<Int>()
        for (index, item) in items.enumerated().reversed() {
            if let sid = item.serverId, messages.contains(where: { $0.serverId == sid }) {
                recognized.insert(index)
                continue
            }

            let itemClientId = item.serverId.flatMap { clientIds[$0] }
            if let itemClientId, !itemClientId.isEmpty {
                if let localIdx = messages.firstIndex(where: {
                    $0.serverId == nil && $0.role == item.role
                        && $0.id.caseInsensitiveCompare(itemClientId) == .orderedSame
                }) {
                    messages[localIdx].serverId = item.serverId
                    // Серверные вложения замещают локальные превью (mediaId пуст): только теперь
                    // у своего же файла есть mediaId, по которому его картинку можно раздать.
                    if !item.attachments.isEmpty { messages[localIdx].attachments = item.attachments }
                    echoFloors[messages[localIdx].id] = nil
                    idConfirmed.insert(messages[localIdx].id)
                    recognized.insert(index)
                }
                // Идентификатор у строки есть, но локального двойника нет — это чужая строка
                // (другое устройство, другой пользователь). Текстовое сопоставление к ней не
                // применяем: оно бы забрало ни в чём не виноватое локальное сообщение.
                continue
            }

            // Сервер знает `clientMessageId`, но у этой строки пользователя его нет — значит,
            // она записана до 0.2.9 (или другим клиентом). Своей она быть не может: всё, что
            // отправил этот экран, ушло с идентификатором.
            if clientIdsSupported, item.role == "user" { continue }

            // Сравнение по ПОДРЕЗАННОМУ тексту: сервер хранит ответ без крайних пробелов, а в
            // потоке они приходят (первым чанком часто идёт перевод строки). Точное равенство
            // роняло слияние в дубль ровно на таких ответах.
            let itemKey = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let localIdx = messages.lastIndex(where: {
                $0.serverId == nil && !$0.streaming && $0.role == item.role
                    && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == itemKey
                    && canBeEcho(item, of: $0)
            }) {
                messages[localIdx].serverId = item.serverId
                messages[localIdx].failed = false
                if !item.attachments.isEmpty { messages[localIdx].attachments = item.attachments }
                echoFloors[messages[localIdx].id] = nil
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
        // Пометку «не отправлено» снимаем только теперь: до вставки остальных строк страницы
        // не видно, есть ли за сообщением ответ. Перебираем ВСЕ подтверждённые сервером строки,
        // а не только узнанные этой страницей: ответ на сообщение приходит СЛЕДУЮЩИМ догоном, и
        // иначе «Повторить» осталось бы на доставленном сообщении до конца сессии.
        for message in messages where message.failed && idConfirmed.contains(message.id) {
            if isSettled(message.id) { setFailed(id: message.id, false) }
        }
        return added
    }

    /// Может ли серверная строка быть эхом локальной.
    ///
    /// Курсор на момент появления локальной строки известен — эхо обязано быть новее него:
    /// серверный id растёт, и это сравнение точное. Курсора не было (история ещё не пришла,
    /// тред пуст) — остаётся время: серверная строка не старше локальной больше, чем на
    /// `echoClockTolerance`. Старые строки, чей текст совпал, эхом не считаются никогда.
    ///
    /// Строка, добавленная в ленту не через `append*` (например, хостом через `replaceAll`),
    /// курсора не имеет и сверяется по времени.
    private func canBeEcho(_ item: ChatMessage, of local: ChatMessage) -> Bool {
        let floor = echoFloors[local.id] ?? 0
        if floor > 0 {
            guard let sid = item.serverId else { return false }
            return sid > floor
        }
        return item.timestamp >= local.timestamp.addingTimeInterval(-Self.echoClockTolerance)
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
        if messages[idx].content.isEmpty {
            messages.remove(at: idx)
            echoFloors[id] = nil
        }
    }

    public func resetForLogout() {
        resetForIdentityChange()
        greeting = nil
    }

    /// Сменился пользователь (выход или другой вход): лента, режим, черновик и курсор
    /// прежнего человека не должны пережить смену. Приветствие остаётся — его задаёт хост,
    /// и к пользователю оно не относится.
    ///
    /// Черновик — это текст в поле ввода `ChatView` (оно привязано к `draft`): набранное,
    /// но не отправленное прежним человеком следующий иначе увидел бы и мог отправить в
    /// свой тред.
    func resetForIdentityChange() {
        messages.removeAll()
        echoFloors.removeAll()
        idConfirmed.removeAll()
        mode = .ai
        operatorTyping = nil
        draft = ""
        sending = false
        connectionError = nil
        lastServerMessageId = 0
        resetOlderPaging()
    }

    /// Сервер выдал устройству ДРУГУЮ строку (прежнюю увели в отставку): у неё свой диалог,
    /// и серверные id прежнего треда к нему не относятся — курсор с ними запросил бы чужие
    /// сообщения, а лежащие в ленте серверные строки к новому диалогу не относятся вовсе.
    ///
    /// Неподтверждённые сообщения пользователя ОСТАЮТСЯ в ленте (с пометкой недоставленных их
    /// оставит контроллер): набранный и отправленный текст нельзя терять молча — он принадлежит
    /// тому же человеку, устройство просто сменило строку.
    func resetForDeviceChange() {
        messages.removeAll { $0.serverId != nil || $0.streaming || $0.role != "user" }
        echoFloors.removeAll()
        idConfirmed.removeAll()
        mode = .ai
        operatorTyping = nil
        lastServerMessageId = 0
        // Старые страницы считались от треда прежней строки — заново их скажет хвост.
        resetOlderPaging()
    }

    private func resetOlderPaging() {
        hasOlder = false
        loadingOlder = false
        olderFailed = false
    }
}
