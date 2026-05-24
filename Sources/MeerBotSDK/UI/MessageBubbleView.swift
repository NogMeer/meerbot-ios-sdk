// MeerBot iOS SDK — Phase 5.b: MessageBubble компонент.

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
                Text(message.content + (message.streaming ? " ▍" : ""))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundColor(bubbleForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
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
        if message.role == "user" {
            return Color.accentColor
        } else {
            return Color(.secondarySystemBackground)
        }
    }

    private var bubbleForeground: Color {
        message.role == "user" ? .white : .primary
    }
}
