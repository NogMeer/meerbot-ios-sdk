// MeerBot iOS SDK — инкрементальный парсер Server-Sent Events.
//
// Эталон протокола — веб-клиент виджета (`widget/src/chat/api/stream.ts` в agentbot-platform):
// события разделены пустой строкой, поля `event:` / `data:`; несколько `data:` в одном блоке
// склеиваются через "\n"; `data: [DONE]` — маркер конца генерации AI.
//
// Почему парсер работает по БАЙТАМ, а не по строкам:
//   TCP-чанк может разрезать многобайтовый UTF-8 символ пополам (кириллица — 2 байта,
//   эмодзи — 4). Декодирование каждого чанка отдельно (`String(data:encoding:.utf8)`)
//   в этом случае возвращает nil и МОЛЧА теряет весь чанк — в чате это выглядит как
//   выпавшие куски ответа. Поэтому граница событий ищется в байтовом буфере, а в текст
//   переводится только целый блок события.

import Foundation

/// Сырое событие SSE: имя (по умолчанию "message") + склеенное тело `data`.
struct SSEEvent: Equatable {
    let name: String
    let data: String
}

/// Инкрементальный парсер. Не потокобезопасен — предполагается вызов из одной задачи.
final class SSEParser {

    private var buffer = Data()

    /// Максимальный размер незавершённого блока. Защита от бесконечного роста буфера,
    /// если сервер (или прокси) отдаёт поток без разделителей событий.
    private let maxBufferBytes: Int

    init(maxBufferBytes: Int = 1_048_576) {
        self.maxBufferBytes = maxBufferBytes
    }

    /// Скормить очередной сетевой чанк. Возвращает все события, завершившиеся в этом чанке.
    func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []

        while let separator = Self.findSeparator(in: buffer) {
            let block = buffer.subdata(in: buffer.startIndex ..< separator.lowerBound)
            buffer.removeSubrange(buffer.startIndex ..< separator.upperBound)
            if let event = Self.parseBlock(block) {
                events.append(event)
            }
        }

        if buffer.count > maxBufferBytes {
            // Мусорный «блок» без разделителя — выбрасываем, чтобы не съесть память.
            // Тихо не проглатываем: следующий валидный блок распарсится как обычно.
            buffer.removeAll(keepingCapacity: false)
        }
        return events
    }

    /// Добрать последний блок, если поток закрылся без завершающей пустой строки.
    func flush() -> [SSEEvent] {
        guard !buffer.isEmpty else { return [] }
        let block = buffer
        buffer.removeAll(keepingCapacity: false)
        guard let event = Self.parseBlock(block) else { return [] }
        return [event]
    }

    // MARK: - Разбор

    /// Ищет границу событий: "\n\n" или "\r\n\r\n" (нормализуем оба — прокси умеют переписывать).
    private static func findSeparator(in data: Data) -> Range<Data.Index>? {
        guard data.count >= 2 else { return nil }
        var index = data.startIndex
        let end = data.endIndex
        while index < end {
            guard let lf = data[index...].firstIndex(of: 0x0A) else { return nil }
            let next = data.index(after: lf)
            if next < end, data[next] == 0x0A {
                return lf ..< data.index(after: next)
            }
            // \r\n\r\n
            if next < end, data[next] == 0x0D {
                let afterCR = data.index(after: next)
                if afterCR < end, data[afterCR] == 0x0A {
                    return lf ..< data.index(after: afterCR)
                }
            }
            index = next
        }
        return nil
    }

    private static func parseBlock(_ block: Data) -> SSEEvent? {
        guard let raw = String(data: block, encoding: .utf8) else { return nil }
        // "\r\n" в Swift — ОДИН Character, и split(separator: "\n") его не находит.
        // Нормализуем до перевода строки, иначе весь блок с CRLF слипается в одну «строку».
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var name = "message"
        var dataLines: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty || line.hasPrefix(":") { continue } // комментарий/keep-alive
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[line.startIndex ..< colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() } // SSE: один ведущий пробел не значим
            switch field {
            case "event": name = value.trimmingCharacters(in: .whitespaces)
            case "data": dataLines.append(value)
            default: continue // id / retry / прочее нам не нужны
            }
        }

        if dataLines.isEmpty && name == "message" { return nil }
        return SSEEvent(name: name, data: dataLines.joined(separator: "\n"))
    }
}
