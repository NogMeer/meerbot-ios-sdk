// Вариант 2 — свой интерфейс поверх состояния SDK.
// Показывает ровно то, что нужно хост-приложению: лента, ошибка с повтором, поле ввода.

import SwiftUI
import MeerBotSDK

struct CustomChatDemo: View {
    @State private var draft = ""

    var body: some View {
        if let controller = MeerBot.shared.chatController() {
            CustomChatBody(controller: controller, draft: $draft)
        } else {
            Text("Сначала вызовите MeerBot.shared.configure(apiKey:)")
                .foregroundColor(.secondary)
                .padding()
        }
    }
}

private struct CustomChatBody: View {
    @ObservedObject var controller: ChatController
    @ObservedObject private var store: ChatStore
    @Binding var draft: String

    init(controller: ChatController, draft: Binding<String>) {
        self.controller = controller
        self.store = controller.store
        self._draft = draft
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.messages) { message in
                        HStack {
                            if message.role == "user" { Spacer(minLength: 48) }
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = message.authorName {
                                    Text(name).font(.caption2).foregroundColor(.secondary)
                                }
                                Text(message.content)
                                    .padding(10)
                                    .background(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    // streaming = ответ ещё дописывается
                                    .opacity(message.streaming ? 0.75 : 1)
                                if message.failed {
                                    Text("не отправлено").font(.caption2).foregroundColor(.red)
                                }
                            }
                            if message.role != "user" { Spacer(minLength: 48) }
                        }
                    }
                }
                .padding()
            }

            if let error = store.connectionError {
                HStack {
                    Text(error).font(.caption).foregroundColor(.red)
                    Spacer()
                    if controller.retryableText != nil {
                        Button("Повторить") { controller.retry() }.font(.caption.bold())
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
            }

            // mode приходит с сервера: кто отвечает прямо сейчас
            if store.mode == .pendingEscalation || store.mode == .human {
                Text(store.mode == .human ? "Отвечает менеджер" : "Зовём менеджера…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }

            HStack {
                TextField("Сообщение", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Отправить") {
                    controller.send(draft)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.sending)
            }
            .padding()
        }
        .onAppear { controller.start() }
    }
}
