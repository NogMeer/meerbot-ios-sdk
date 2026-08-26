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

    func testВыходСбрасываетКурсор() {
        let store = ChatStore()
        store.mergeServerMessages([serverMessage(42, text: "a")])

        store.resetForLogout()

        XCTAssertEqual(store.lastServerMessageId, 0)
        XCTAssertTrue(store.messages.isEmpty)
    }
}
