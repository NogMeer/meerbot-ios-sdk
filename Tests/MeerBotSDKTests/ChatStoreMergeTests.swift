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

    // MARK: - Сопоставление по `clientMessageId`

    /// Точное сопоставление сильнее всех догадок: текст сервер подрезал/изменил (менеджер
    /// правил), серверный id НИЖЕ курсора на момент отправки, а время строки на 10 минут
    /// позади устройства — по тексту и часам такая строка эхом не считалась бы ни за что.
    func testПромоутПоIdИгнорируетТекстКурсорИЧасы() {
        let store = ChatStore()
        store.mergeServerMessages([serverMessage(40, text: "последнее известное")])
        store.noteClientIdsSupported()
        let local = store.appendUserMessage("нужен счёт на оплату")

        let added = store.mergeServerMessages(
            [
                ChatMessage(
                    serverId: 12,
                    role: "user",
                    content: "другой текст",
                    timestamp: Date().addingTimeInterval(-600)
                ),
            ],
            clientIds: [12: local.id]
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.last?.id, local.id)
        XCTAssertEqual(store.messages.last?.serverId, 12)
        XCTAssertTrue(store.isIdConfirmed(local.id))
    }

    /// Сервер отдаёт id в нижнем регистре, локальный `UUID` — в верхнем: регистр не должен
    /// решать, узнает экран своё сообщение или покажет его дважды.
    func testПромоутПоIdНеЗависитОтРегистра() {
        let store = ChatStore()
        store.noteClientIdsSupported()
        let local = store.appendUserMessage("привет")

        let added = store.mergeServerMessages(
            [serverMessage(3, role: "user", text: "привет")],
            clientIds: [3: local.id.lowercased()]
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.messages.map(\.serverId), [3])
    }

    /// Два одинаковых «да» подряд: по тексту их не различить, по id — точно. Перепутанные
    /// местами, они дали бы неверную сверку «на это ответили, на то нет».
    func testДваОдинаковыхДаРазводятсяПоId() {
        let store = ChatStore()
        store.noteClientIdsSupported()
        let first = store.appendUserMessage("да")
        let second = store.appendUserMessage("да")

        let added = store.mergeServerMessages(
            [
                serverMessage(21, role: "user", text: "да"),
                serverMessage(22, role: "user", text: "да"),
            ],
            clientIds: [21: first.id, 22: second.id]
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.messages.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.messages.map(\.serverId), [21, 22])
    }

    /// У строки есть ЧУЖОЙ `clientMessageId` (другое устройство того же человека): локального
    /// двойника нет, и по тексту её сопоставлять нельзя — иначе своё сообщение получило бы
    /// чужой id, а сверка после обрыва сочла бы его доставленным.
    func testЧужойIdПоТекстуНеСопоставляется() {
        let store = ChatStore()
        store.noteClientIdsSupported()
        let local = store.appendUserMessage("да")

        let added = store.mergeServerMessages(
            [serverMessage(31, role: "user", text: "да")],
            clientIds: [31: UUID().uuidString.lowercased()]
        )

        XCTAssertEqual(added, 1)
        // Чужая строка встала рядом, своя осталась неподтверждённой — и это правильно: сверка
        // после обрыва увидит, что сообщение до сервера не дошло.
        XCTAssertEqual(store.messages.map(\.serverId), [nil, 31])
        XCTAssertEqual(store.messages.first?.id, local.id)
        XCTAssertFalse(store.isIdConfirmed(local.id))
    }

    /// Сервер умеет идентификаторы, а у строки пользователя его нет (записана до 0.2.9 или
    /// другим клиентом) — своей она быть не может: всё, что ушло с этого экрана, несло id.
    func testБезIdПриПоддержкеСерверомСтрокаПользователяНеЭхо() {
        let store = ChatStore()
        store.noteClientIdsSupported()
        let local = store.appendUserMessage("привет")

        let added = store.mergeServerMessages([serverMessage(9, role: "user", text: "привет")], clientIds: [:])

        XCTAssertEqual(added, 1)
        XCTAssertNil(store.messages.first { $0.id == local.id }?.serverId)
    }

    /// Строка сервера несёт ЧУЖОЙ идентификатор (другое устройство того же человека): по тексту
    /// её сопоставлять нельзя — иначе экран отдал бы ей своё, ещё не дошедшее сообщение и снял
    /// бы с него «Повторить».
    func testСтрокаСЧужимIdПоТекстуНеСопоставляется() {
        let store = ChatStore()
        store.noteClientIdsSupported()
        let local = store.appendUserMessage("привет")
        store.setFailed(id: local.id, true)

        let added = store.mergeServerMessages(
            [serverMessage(9, role: "user", text: "привет")],
            clientIds: [9: "11111111-2222-4333-8444-555555555555"]
        )

        XCTAssertEqual(added, 1, "чужая строка добавляется отдельной")
        XCTAssertNil(store.messages.first { $0.id == local.id }?.serverId)
        XCTAssertEqual(store.messages.first { $0.id == local.id }?.failed, true)
        XCTAssertFalse(store.isIdConfirmed(local.id))
    }

    /// Ответ ассистента сопоставляется по тексту и при поддержке идентификаторов: своего id у
    /// него нет и быть не может (его пишет сервер), а пузырь потока узнавать надо.
    func testОтветАссистентаПриПоддержкеIdСопоставляетсяПоТексту() {
        let store = ChatStore()
        store.noteClientIdsSupported()
        let placeholder = store.appendAssistantPlaceholder()
        store.updateAssistantContent(id: placeholder.id, delta: "Готово")
        store.finalizeAssistant(id: placeholder.id)

        XCTAssertEqual(store.mergeServerMessages([serverMessage(14, text: "Готово")], clientIds: [:]), 0)
        XCTAssertEqual(store.messages.map(\.serverId), [14])
    }

    /// Старый сервер идентификаторов не присылает: сопоставление по тексту остаётся
    /// единственным и работает как до 0.2.9.
    func testСтарыйСерверСопоставляетПоТекстуКакПрежде() {
        let store = ChatStore()
        let local = store.appendUserMessage("не приходит письмо")

        let added = store.mergeServerMessages(
            [serverMessage(7, role: "user", text: "не приходит письмо")],
            clientIds: [:]
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.messages.map(\.id), [local.id])
        XCTAssertEqual(store.messages.first?.serverId, 7)
        XCTAssertFalse(store.isIdConfirmed(local.id), "по тексту — догадка, а не подтверждение сервера")
    }

    /// «Записал» и «ответил» — разные вещи: пока за сообщением на сервере ничего нет, кнопка
    /// «Повторить» остаётся (повтор идемпотентен). Ответ в той же странице её снимает.
    func testПометкаНеОтправленоСнимаетсяТолькоКогдаЗаСообщениемЕстьОтвет() {
        let store = ChatStore()
        store.noteClientIdsSupported()
        let local = store.appendUserMessage("нужен счёт")
        store.setFailed(id: local.id, true)

        store.mergeServerMessages([serverMessage(50, role: "user", text: "нужен счёт")], clientIds: [50: local.id])
        XCTAssertTrue(store.messages.first { $0.id == local.id }?.failed == true, "ответа ещё нет")

        store.mergeServerMessages([serverMessage(51, text: "секунду")], clientIds: [:])
        XCTAssertFalse(store.messages.first { $0.id == local.id }?.failed == true)
    }

    /// Подтверждение из `meta` приходит до страницы истории: строка получает серверный id, но
    /// курсор ленты не двигается — иначе догон пропустил бы всё, что лежит между.
    func testПодтверждениеПоIdНеДвигаетКурсор() {
        let store = ChatStore()
        let local = store.appendUserMessage("привет")

        store.confirmUserMessage(localId: local.id, serverId: 77)

        XCTAssertEqual(store.messages.first?.serverId, 77)
        XCTAssertEqual(store.lastServerMessageId, 0)
        XCTAssertTrue(store.isIdConfirmed(local.id))
    }

    /// Сброс ленты обязан забыть и подтверждения: иначе после смены устройства строка с
    /// прежним серверным id считалась бы принятой новым устройством.
    func testСбросыЧистятПодтверждения() {
        let store = ChatStore()
        let local = store.appendUserMessage("привет")
        store.confirmUserMessage(localId: local.id, serverId: 5)

        store.resetForIdentityChange()

        XCTAssertFalse(store.isIdConfirmed(local.id))
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
