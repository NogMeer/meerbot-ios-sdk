import XCTest
@testable import MeerBotSDK

/// Слияние серверной страницы в ленту — фундамент догона: SDK опрашивает
/// `GET /mobile/messages?since=` пока экран открыт, и одна и та же страница неизбежно
/// приходит повторно. Ошибка здесь видна пользователю сразу — дублем своего же сообщения.
@MainActor
final class ChatStoreMergeTests: XCTestCase {

    private func serverMessage(_ id: Int, role: String = "assistant", text: String) -> ChatMessage {
        ChatMessage(
            serverId: id,
            role: role,
            author: role == "assistant" ? "manager" : nil,
            authorName: role == "assistant" ? "Роман" : nil,
            content: text
        )
    }

    func testПовторнаяСтраницаНичегоНеМеняет() {
        let store = ChatStore()
        let page = [serverMessage(10, text: "уже смотрю")]

        XCTAssertEqual(store.mergeServerMessages(page), 1)
        XCTAssertEqual(store.mergeServerMessages(page), 0)
        XCTAssertEqual(store.messages.count, 1)
    }

    /// Своё сообщение приходит с сервера с id — оно обязано ПРОМОУТИТЬСЯ, а не удвоиться.
    func testЛокальноеСообщениеПромоутитсяВСерверное() {
        let store = ChatStore()
        let local = store.appendUserMessage("не приходит письмо")
        store.setFailed(id: local.id, true)

        let added = store.mergeServerMessages([serverMessage(7, role: "user", text: "не приходит письмо")])

        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].serverId, 7)
        // Пометка «не доставлено» снимается: сервер строку принял, кнопка «Повторить» лишняя.
        XCTAssertFalse(store.messages[0].failed)
        // id для SwiftUI не меняется — иначе список перерисовал бы строку как новую.
        XCTAssertEqual(store.messages[0].id, local.id)
    }

    func testОтветМенеджераДобавляетсяВКонецЛенты() {
        let store = ChatStore()
        store.appendUserMessage("позови человека")

        store.mergeServerMessages([serverMessage(11, text: "я тут")])

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.last?.author, "manager")
        XCTAssertEqual(store.messages.last?.authorName, "Роман")
    }

    func testКурсорРастётМонотонноИНеОткатываетсяСтаройСтраницей() {
        let store = ChatStore()

        store.mergeServerMessages([serverMessage(10, text: "a"), serverMessage(12, text: "b")])
        XCTAssertEqual(store.lastServerMessageId, 12)

        store.mergeServerMessages([serverMessage(5, text: "старое")])
        XCTAssertEqual(store.lastServerMessageId, 12)
    }

    /// Иначе догон вечно перезапрашивал бы одни и те же строки: курсор не сдвинулся бы.
    func testКурсорДвигаетсяДажеЕслиВсяСтраницаПропущена() {
        let store = ChatStore()
        let page = [serverMessage(20, text: "уже есть")]
        store.mergeServerMessages(page)

        store.mergeServerMessages(page)

        XCTAssertEqual(store.lastServerMessageId, 20)
    }

    func testReplaceAllПоднимаетКурсор() {
        let store = ChatStore()

        store.replaceAll([serverMessage(3, text: "a"), serverMessage(9, text: "b")])

        XCTAssertEqual(store.lastServerMessageId, 9)
    }

    /// Регрессия: поток начинается с перевода строки (модель стабильно так отвечает на
    /// передачу менеджеру), сервер хранит строку подрезанной. До правки слияние не узнавало
    /// свой же ответ и клало серверную копию рядом — пользователь видел сообщение дважды.
    func testОтветСПереводомСтрокиВНачалеПотокаНеДвоится() {
        let store = ChatStore()
        let placeholder = store.appendAssistantPlaceholder()
        store.updateAssistantContent(id: placeholder.id, delta: "\n")
        store.updateAssistantContent(id: placeholder.id, delta: "Понимаю, сейчас подключу менеджера.")
        store.finalizeAssistant(id: placeholder.id)

        let added = store.mergeServerMessages(
            [serverMessage(11, text: "Понимаю, сейчас подключу менеджера.")]
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.serverId, 11)
        XCTAssertEqual(store.messages.first?.content, "Понимаю, сейчас подключу менеджера.")
    }

    /// Хвостовые пробелы потока тоже не должны мешать слиянию.
    func testХвостовойПереносСтрокиНеМешаетСлиянию() {
        let store = ChatStore()
        let placeholder = store.appendAssistantPlaceholder()
        store.updateAssistantContent(id: placeholder.id, delta: "Готово")
        store.updateAssistantContent(id: placeholder.id, delta: "\n\n")
        store.finalizeAssistant(id: placeholder.id)

        XCTAssertEqual(store.mergeServerMessages([serverMessage(12, text: "Готово")]), 0)
        XCTAssertEqual(store.messages.count, 1)
    }

    // MARK: - Порядок относительно неподтверждённых сообщений

    private func olderServerMessage(_ id: Int, role: String = "assistant", text: String) -> ChatMessage {
        ChatMessage(
            serverId: id,
            role: role,
            content: text,
            timestamp: Date().addingTimeInterval(-86_400)
        )
    }

    /// Стартовая история пришла после отправки: её строки старше ждущего сообщения.
    func testСтраницаСтарееЖдущегоСообщенияВстаётПередНим() {
        let store = ChatStore()
        store.appendUserMessage("привет")
        let placeholder = store.appendAssistantPlaceholder()
        store.updateAssistantContent(id: placeholder.id, delta: "Отве")

        let added = store.mergeServerMessages([
            olderServerMessage(1, role: "user", text: "вчера"),
            olderServerMessage(2, text: "ответ вчера"),
        ])

        XCTAssertEqual(added, 2)
        XCTAssertEqual(store.messages.map(\.content), ["вчера", "ответ вчера", "привет", "Отве"])
        XCTAssertEqual(store.messages.last?.id, placeholder.id, "поток продолжает писать в тот же пузырь")
        XCTAssertEqual(store.messages.last?.streaming, true)
    }

    /// Стримящийся пузырь ещё дописывается: промоут снял бы `streaming`, а серверная строка
    /// с тем же текстом — не его окончательная версия.
    func testСтримящийсяОтветНеПромоутится() {
        let store = ChatStore()
        let placeholder = store.appendAssistantPlaceholder()
        store.updateAssistantContent(id: placeholder.id, delta: "Готово")

        store.mergeServerMessages([olderServerMessage(5, text: "Готово")])

        let bubble = store.messages.first { $0.id == placeholder.id }
        XCTAssertNil(bubble?.serverId)
        XCTAssertEqual(bubble?.streaming, true)
        XCTAssertEqual(store.messages.count, 2)
    }

    /// Пользователь повторил вчерашний текст. Эхо — самая новая строка с этим текстом;
    /// вчерашняя не должна «съесть» ждущее сообщение.
    func testЭхоЗабираетСамаяНоваяСтрокаСТемЖеТекстом() {
        let store = ChatStore()
        let local = store.appendUserMessage("ок")

        store.mergeServerMessages([
            olderServerMessage(1, role: "user", text: "ок"),
            olderServerMessage(2, text: "Принято"),
            serverMessage(3, role: "user", text: "ок"),
        ])

        XCTAssertEqual(store.messages.map(\.serverId), [1, 2, 3])
        XCTAssertEqual(store.messages.last?.id, local.id)
    }

    /// Порядок между серверными строками — по серверному id, даже если страница пришла
    /// после неподтверждённого сообщения, которое старше части из них.
    func testСерверныеСтрокиВстаютПоIdВокругНедоставленного() {
        let store = ChatStore()
        store.mergeServerMessages([olderServerMessage(1, role: "user", text: "a"), olderServerMessage(2, text: "b")])
        let failed = store.appendUserMessage("не ушло")
        store.setFailed(id: failed.id, true)

        store.mergeServerMessages([serverMessage(5, text: "менеджер ответил")])
        store.mergeServerMessages([olderServerMessage(4, text: "пропущенная строка")])

        XCTAssertEqual(
            store.messages.map(\.content),
            ["a", "b", "пропущенная строка", "не ушло", "менеджер ответил"]
        )
    }

    /// Курсора на момент отправки не было (история ещё не пришла). Вчерашнее «да» с ответом
    /// эхом сегодняшнего не становится: иначе строка получила бы чужой id, вчерашняя пропала
    /// бы из ленты, а сверка после обрыва сочла бы недошедшее сообщение доставленным.
    func testВчерашнийТотЖеТекстНеЭхо() {
        let store = ChatStore()
        let local = store.appendUserMessage("да")

        store.mergeServerMessages([
            olderServerMessage(5, role: "user", text: "да"),
            olderServerMessage(6, text: "Записал"),
        ])

        XCTAssertEqual(store.messages.map(\.content), ["да", "Записал", "да"])
        XCTAssertEqual(store.messages.last?.id, local.id)
        XCTAssertNil(store.messages.last?.serverId)
    }

    /// Курсор на момент отправки известен — эхо обязано быть новее него, даже если по времени
    /// строка подходит (часы устройства и сервера расходятся).
    func testСтрокаНеНовееКурсораНаМоментОтправкиНеЭхо() {
        let store = ChatStore()
        store.mergeServerMessages([serverMessage(7, text: "последнее известное")])
        let local = store.appendUserMessage("да")

        store.mergeServerMessages([serverMessage(5, role: "user", text: "да")])
        XCTAssertNil(store.messages.first { $0.id == local.id }?.serverId, "строка 5 существовала до отправки")

        store.mergeServerMessages([serverMessage(9, role: "user", text: "да")])
        XCTAssertEqual(store.messages.first { $0.id == local.id }?.serverId, 9)
    }

    /// Расхождение часов в пределах допуска эху не мешает.
    func testЭхоСЧасамиСервераЧутьПозадиУзнаётся() {
        let store = ChatStore()
        let local = store.appendUserMessage("привет")

        store.mergeServerMessages([
            ChatMessage(serverId: 3, role: "user", content: "привет", timestamp: Date().addingTimeInterval(-120)),
        ])

        XCTAssertEqual(store.messages.map(\.id), [local.id])
        XCTAssertEqual(store.messages.first?.serverId, 3)
    }

    func testСбросIdentityСтираетЧерновик() {
        let store = ChatStore()
        store.setDraft("не отправлено")

        store.resetForIdentityChange()

        XCTAssertEqual(store.draft, "")
    }

    func testСбросIdentityСтираетНеподтверждённыеСообщения() {
        let store = ChatStore()
        store.mergeServerMessages([serverMessage(1, text: "a")])
        let failed = store.appendUserMessage("не ушло")
        store.setFailed(id: failed.id, true)
        store.appendAssistantPlaceholder()

        store.resetForIdentityChange()

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.lastServerMessageId, 0)
    }

    func testВыходСбрасываетКурсор() {
        let store = ChatStore()
        store.mergeServerMessages([serverMessage(42, text: "a")])

        store.resetForLogout()

        XCTAssertEqual(store.lastServerMessageId, 0)
        XCTAssertTrue(store.messages.isEmpty)
    }
}
