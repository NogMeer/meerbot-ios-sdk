// MeerBot iOS SDK — пузырь сообщения.

import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer(minLength: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let authorName = message.authorName, message.author == "manager" {
                    Text(authorName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Group {
                    if message.streaming && message.content.isEmpty {
                        // Модель ещё думает — текста нет вовсе. Раньше здесь оставался
                        // ОДИН символ `▍`, и пузырь выглядел как обрывок непонятного глифа:
                        // человек не понимал, ответ это или сбой. Три пульсирующие точки —
                        // то, чем «собеседник печатает» показывают все мессенджеры, и
                        // объяснять их не нужно.
                        TypingIndicator()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .accessibilityLabel("Ассистент печатает")
                    } else if message.streaming {
                        // Текст уже пошёл — курсор в конце строки читается как курсор
                        // (так делают ChatGPT и Claude), но ТОЛЬКО мигающий: статичный
                        // символ в конце ответа неотличим от опечатки бота.
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            let visible = Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
                            Text(message.content + (visible ? "▍" : ""))
                        }
                    } else {
                        Text(message.content)
                    }
                }
                .padding(.horizontal, message.streaming && message.content.isEmpty ? 0 : 12)
                .padding(.vertical, message.streaming && message.content.isEmpty ? 0 : 8)
                .background(bubbleBackground)
                .foregroundColor(bubbleForeground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
                .opacity(message.failed ? 0.6 : 1)
                if message.failed {
                    Label("Не отправлено", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
            if message.role != "user" {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }

    private var bubbleBackground: Color {
        message.role == "user" ? Color.accentColor : Color.mbSurfaceSecondary
    }

    private var bubbleForeground: Color {
        message.role == "user" ? .white : .primary
    }
}
