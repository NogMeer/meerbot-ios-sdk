// Разбор SSE: границы событий, склейка многострочных data, устойчивость к произвольной
// нарезке сетевых чанков (включая разрыв UTF-8 посреди символа).

import XCTest
@testable import MeerBotSDK

final class SSEParserTests: XCTestCase {

    private func feed(_ parser: SSEParser, _ text: String) -> [SSEEvent] {
        parser.feed(Data(text.utf8))
    }

    func testРазбираетСобытиеСИменемИТелом() {
        let parser = SSEParser()
        let events = feed(parser, "event: meta\ndata: {\"conversationId\":42,\"mode\":\"ai\"}\n\n")
        XCTAssertEqual(events, [SSEEvent(name: "meta", data: "{\"conversationId\":42,\"mode\":\"ai\"}")])
    }

    func testСобытиеБезИмениПолучаетИмяMessage() {
        let parser = SSEParser()
        let events = feed(parser, "data: {\"choices\":[]}\n\n")
        XCTAssertEqual(events.first?.name, "message")
    }

    func testНесколькоСобытийВОдномЧанке() {
        let parser = SSEParser()
        let events = feed(parser, "event: heartbeat\ndata: {}\n\ndata: [DONE]\n\n")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].name, "heartbeat")
        XCTAssertEqual(events[1].data, "[DONE]")
    }

    func testСобытиеРазрезанноеМеждуЧанкамиСобираетсяЦеликом() {
        let parser = SSEParser()
        XCTAssertTrue(feed(parser, "event: me").isEmpty)
        XCTAssertTrue(feed(parser, "ta\ndata: {\"conversa").isEmpty)
        XCTAssertTrue(feed(parser, "tionId\":7}\n").isEmpty, "одиночный \\n — ещё не граница события")
        let events = feed(parser, "\n")
        XCTAssertEqual(events, [SSEEvent(name: "meta", data: "{\"conversationId\":7}")])
    }

    /// Регрессия: посимвольное декодирование чанков теряло кириллицу, если TCP-граница
    /// проходила посреди двухбайтового символа.
    func testРазрывUTF8ПосредиСимволаНеТеряетТекст() {
        let parser = SSEParser()
        let payload = Data("data: {\"text\":\"Привет, как дела?\"}\n\n".utf8)
        var collected: [SSEEvent] = []
        // Режем по одному байту — худший случай для любой построчной сборки.
        for index in payload.indices {
            collected += parser.feed(payload.subdata(in: index ..< payload.index(after: index)))
        }
        XCTAssertEqual(collected.first?.data, "{\"text\":\"Привет, как дела?\"}")
    }

    func testМногострочныйDataСклеиваетсяЧерезПереводСтроки() {
        let parser = SSEParser()
        let events = feed(parser, "data: первая\ndata: вторая\n\n")
        XCTAssertEqual(events.first?.data, "первая\nвторая")
    }

    func testКомментарииИПустыеСтрокиИгнорируются() {
        let parser = SSEParser()
        let events = feed(parser, ": keep-alive\nevent: heartbeat\ndata: {}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, "heartbeat")
    }

    func testПоддерживаетсяРазделительCRLF() {
        let parser = SSEParser()
        let events = feed(parser, "event: done\r\ndata: [DONE]\r\n\r\n")
        XCTAssertEqual(events, [SSEEvent(name: "done", data: "[DONE]")])
    }

    func testFlushОтдаётПоследнийБлокБезЗавершающейПустойСтроки() {
        let parser = SSEParser()
        XCTAssertTrue(feed(parser, "event: error\ndata: {\"code\":\"ai_unavailable\"}").isEmpty)
        XCTAssertEqual(parser.flush().first?.name, "error")
        XCTAssertTrue(parser.flush().isEmpty, "повторный flush пуст")
    }

    func testБуферНеРастётБесконечноНаПотокеБезРазделителей() {
        let parser = SSEParser(maxBufferBytes: 64)
        XCTAssertTrue(parser.feed(Data(repeating: 0x41, count: 4096)).isEmpty)
        // Мусор отброшен — следующее корректное событие разбирается как обычно.
        XCTAssertEqual(feed(parser, "event: heartbeat\ndata: {}\n\n").first?.name, "heartbeat")
    }

    // MARK: Отображение в типизированные события

    func testЧанкГенерацииПревращаетсяВДельтуТекста() {
        let sse = SSEEvent(name: "message", data: "{\"choices\":[{\"delta\":{\"content\":\"Здрав\"}}]}")
        XCTAssertEqual(ChatStreamEvent.from(sse), .contentDelta("Здрав"))
    }

    func testПустойЧанкПропускается() {
        let sse = SSEEvent(name: "message", data: "{\"choices\":[{\"delta\":{}}]}")
        XCTAssertNil(ChatStreamEvent.from(sse))
    }

    func testDoneРаспознаётсяДоРазбораJSON() {
        XCTAssertEqual(ChatStreamEvent.from(SSEEvent(name: "message", data: "[DONE]")), .done)
    }

    func testMetaНесётIdДиалогаИРежим() {
        let sse = SSEEvent(name: "meta", data: "{\"conversationId\":15,\"mode\":\"pending_escalation\"}")
        XCTAssertEqual(ChatStreamEvent.from(sse), .meta(conversationId: 15, mode: .pendingEscalation))
    }

    func testОтветМенеджера() {
        let sse = SSEEvent(
            name: "manager_message",
            data: "{\"messageId\":88,\"text\":\"Уже смотрю\",\"authorName\":\"Марат\"}"
        )
        XCTAssertEqual(
            ChatStreamEvent.from(sse),
            .managerMessage(ManagerMessage(messageId: 88, text: "Уже смотрю", authorName: "Марат"))
        )
    }

    func testОшибкаСервера() {
        let sse = SSEEvent(name: "error", data: "{\"code\":\"ai_unavailable\",\"message\":\"AI down\"}")
        XCTAssertEqual(ChatStreamEvent.from(sse), .serverError(code: "ai_unavailable", message: "AI down"))
    }

    func testНеизвестноеСобытиеНеЛомаетКлиента() {
        let sse = SSEEvent(name: "quantum_flux", data: "{}")
        XCTAssertEqual(ChatStreamEvent.from(sse), .unknown(name: "quantum_flux"))
    }
}
