// MeerBot iOS SDK — экран чата (SwiftUI).
//
// View тонкий: всё поведение — в ChatController. Контракт совпадает с Android Compose
// ChatScreen и RN ChatScreen.

import SwiftUI

public struct ChatView: View {

    @ObservedObject private var controller: ChatController
    @ObservedObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    private let title: String
    private let primaryColor: Color
    private let onClose: (() -> Void)?

    /// Фокус поля ввода. Живёт ЗДЕСЬ, а не в `ChatInput`: снимать его должен список
    /// сообщений по тапу, а из дочернего вью до чужого `@FocusState` не дотянуться.
    @FocusState private var inputFocused: Bool

    /// - Parameter controller: связка с API. `MeerBot.shared.chatView()` передаёт свой;
    ///   отдельный контроллер нужен, только если приложение ведёт несколько независимых чатов.
    public init(
        controller: ChatController,
        title: String = "Поддержка",
        primaryColor: Color = .blue,
        onClose: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.store = controller.store
        self.title = title
        self.primaryColor = primaryColor
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ChatHeader(
                title: title,
                primaryColor: primaryColor,
                onClose: {
                    // Отклик — ДО закрытия: экран уезжает мгновенно, и вызванный после
                    // генератор успел бы уйти из памяти вместе с вью.
                    MBHaptics.lightImpact()
                    onClose?()
                    dismiss()
                }
            )
            Divider()
            MessagesList(store: store)
                // ТАП по переписке убирает клавиатуру. Протягивания
                // (`scrollDismissesKeyboard`) недостаточно: оно требует, чтобы списку было
                // куда прокручиваться, а в свежем диалоге сообщений одно-два — тянуть
                // нечего, и выйти из ввода было нечем вовсе.
                //
                // `contentShape` обязателен: у `ScrollView` пустое место не входит в
                // площадь попадания, и тап мимо пузыря — а это как раз «пустое место», по
                // которому целится человек, — не доходил бы до жеста.
                .contentShape(Rectangle())
                .onTapGesture { inputFocused = false }
            if let typing = store.operatorTyping {
                HStack(spacing: 8) {
                    TypingIndicator()
                    Text("\(typing) печатает…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            if let err = store.connectionError {
                ConnectionBanner(
                    text: err,
                    canRetry: controller.retryableText != nil,
                    onRetry: { controller.retry() }
                )
            }
            ChatInput(
                store: store,
                primaryColor: primaryColor,
                isFocused: $inputFocused,
                onSend: { controller.send($0) }
            )
        }
        .background(Color.mbSurface)
        .accentColor(primaryColor)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}

private struct ChatHeader: View {
    let title: String
    let primaryColor: Color
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Закрыть чат")
        }
        .padding()
        .background(Color.mbSurface)
    }
}

private struct ConnectionBanner: View {
    let text: String
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if canRetry {
                Button("Повторить", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Повторить отправку")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
    }
}

struct MessagesList: View {
    @ObservedObject var store: ChatStore

    /// Первая порция истории уже показана? До неё прыжок вниз делается БЕЗ анимации.
    ///
    /// История грузится асинхронно уже после открытия экрана, поэтому анимированный
    /// скролл на ней читается как «чат открылся сверху и поехал вниз» — мессенджеры
    /// так себя не ведут, переписка обязана открываться сразу на последнем сообщении.
    /// Анимация остаётся там, где она уместна: новое сообщение в открытом чате.
    @State private var didInitialScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            scrollView(proxy: proxy)
        }
    }

    /// Протягивание переписки убирает клавиатуру — так ведёт себя любой мессенджер,
    /// и без этого выйти из ввода нечем: своей кнопки «Готово» у поля нет, а хост-
    /// приложение обычно показывает экран без навигационной панели.
    ///
    /// `scrollDismissesKeyboard` появился в iOS 16; на iOS 15 остаётся прежнее
    /// поведение — клавиатуру там закрывает хост-приложение своими средствами.
    @ViewBuilder
    private func scrollView(proxy: ScrollViewProxy) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            list(proxy: proxy).scrollDismissesKeyboard(.interactively)
        } else {
            list(proxy: proxy)
        }
    }

    private func list(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.messages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(store.greeting ?? "Привет! Чем могу помочь?")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                } else {
                    ForEach(store.messages) { msg in
                        MessageBubbleView(message: msg)
                            .id(msg.id)
                    }
                }
            }
        }
        // Открытие экрана. Одного `onChange` мало: `ChatStore` живёт в синглтоне
        // `MeerBot.shared` и переживает закрытие чата, поэтому при ПОВТОРНОМ открытии
        // список уже непустой, `messages.count` не меняется — и `onChange` не срабатывает
        // вовсе. Без этой ветки второй заход в чат всегда открывался сверху.
        .onAppear { jumpToBottom(proxy, animated: false) }
        .onChange(of: store.messages.count) { _ in
            // Первый приход истории — мгновенно (экран должен ОТКРЫТЬСЯ внизу, а не
            // доехать туда); дальше новые сообщения — с анимацией, как в мессенджерах.
            jumpToBottom(proxy, animated: didInitialScroll)
        }
    }

    private func jumpToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = store.messages.last else { return }
        didInitialScroll = true

        if animated {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            return
        }

        proxy.scrollTo(last.id, anchor: .bottom)
        // Второй проход после кадра отрисовки: список ленивый (`LazyVStack`), и в момент
        // открытия нижние ячейки ещё не материализованы — `scrollTo` по их id тогда не
        // срабатывает вовсе, и чат так и остаётся сверху.
        DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

struct TypingIndicator: View {
    @State private var bounce = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(bounce ? 1.0 : 0.6)
                    .animation(
                        Animation.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                        value: bounce
                    )
            }
        }
        .onAppear { bounce = true }
        .accessibilityHidden(true)
    }
}

struct ChatInput: View {
    @ObservedObject var store: ChatStore
    let primaryColor: Color
    /// Фокус ввода принадлежит экрану целиком (см. `ChatView.inputFocused`).
    @FocusState.Binding var isFocused: Bool
    let onSend: (String) -> Void

    @State private var localDraft: String = ""

    private var trimmed: String {
        localDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var textField: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            TextField("Сообщение…", text: $localDraft, axis: .vertical)
                .lineLimit(1...4)
        } else {
            TextField("Сообщение…", text: $localDraft)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Многострочный ввод (`axis:`) появился только в iOS 16 — на iOS 15
            // остаётся однострочное поле, всё остальное поведение то же.
            textField
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.mbSurfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(store.mode == .closed)
            Button(action: {
                guard !trimmed.isEmpty, !store.sending, store.mode != .closed else { return }
                let text = trimmed
                localDraft = ""
                onSend(text)
            }) {
                Image(systemName: "paperplane.fill")
                    .padding(8)
                    .background(primaryColor)
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .disabled(trimmed.isEmpty || store.sending)
            .accessibilityLabel("Отправить")
        }
        .padding(8)
        .background(Color.mbSurface)
    }
}
