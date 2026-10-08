// MeerBot iOS SDK — экран чата (SwiftUI).
//
// View тонкий: всё поведение — в ChatController. Контракт совпадает с Android Compose
// ChatScreen и RN ChatScreen.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct ChatView: View {

    @ObservedObject private var controller: ChatController
    @ObservedObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    private let title: String
    private let primaryColor: Color
    private let onClose: (() -> Void)?
    /// Рисовать ли шапку (заголовок + крестик). `false` — когда чат открыт вкладкой хоста:
    /// заголовок там уже есть в его навигации, а вторая полоса с тем же словом съедает высоту.
    private let showHeader: Bool

    /// Фокус поля ввода. Живёт ЗДЕСЬ, а не в `ChatInput`: снимать его должен список
    /// сообщений по тапу, а из дочернего вью до чужого `@FocusState` не дотянуться.
    @FocusState private var inputFocused: Bool

    /// - Parameter controller: связка с API. `MeerBot.shared.chatView()` передаёт свой;
    ///   отдельный контроллер нужен, только если приложение ведёт несколько независимых чатов.
    public init(
        controller: ChatController,
        title: String = "Поддержка",
        primaryColor: Color = .blue,
        onClose: (() -> Void)? = nil,
        showHeader: Bool = true
    ) {
        self.controller = controller
        self.store = controller.store
        self.title = title
        self.primaryColor = primaryColor
        self.onClose = onClose
        self.showHeader = showHeader
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showHeader {
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
            }
            MessagesList(
                store: store,
                onRetry: { controller.retry(messageId: $0) },
                loadMedia: { try await controller.loadMedia(messageId: $0, mediaId: $1) },
                onLoadOlder: { controller.loadOlder() }
            )
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
                onSend: { controller.send($0) },
                onSendAttachments: { controller.send($0, attachments: $1) }
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
    /// Тап по недоставленному пузырю — повтор именно этой строки.
    let onRetry: (String) -> Void
    /// Загрузчик картинок вложений — прокидывается в пузырь.
    let loadMedia: MediaLoader
    /// Подгрузить страницу более старых сообщений (верх ленты стал виден).
    let onLoadOlder: () -> Void

    /// Верх ленты (строка статуса над первым сообщением) сейчас на экране.
    @State private var topVisible = false
    /// Первое сообщение ДО подгрузки старых: после вставки сверху прокрутка возвращается к
    /// нему — SwiftUI держит смещение в точках, а не сообщение, и без этого лента прыгала бы
    /// к самым старым.
    @State private var olderAnchorId: String?

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
            // `.equatable()` — из-за черновика. Поле ввода привязано к `ChatStore.draft`, и
            // каждая буква публикует изменение всего стора: этот вью перестраивается. Сама
            // лента при этом не пересобирается — массив тот же, и сравнение отвечает сразу.
            MessagesFeed(
                messages: store.messages,
                greeting: store.greeting,
                older: OlderHistoryState(
                    hasOlder: store.hasOlder,
                    loading: store.loadingOlder,
                    failed: store.olderFailed
                ),
                onRetry: onRetry,
                loadMedia: loadMedia,
                onTopVisible: { visible in
                    topVisible = visible
                    if visible { requestOlder() }
                },
                onRetryOlder: { requestOlder(force: true) }
            )
            .equatable()
        }
        // Старые сообщения встали сверху — вернуть на экран то, что пользователь видел.
        .onChange(of: store.messages.first?.id) { first in
            guard let anchor = olderAnchorId, first != anchor else { return }
            olderAnchorId = nil
            proxy.scrollTo(anchor, anchor: .top)
            // Второй проход после кадра: ячейки над якорем материализуются лениво.
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        }
        // Первый доскролл вниз состоялся, а верх всё ещё виден (хвост короче экрана) —
        // onAppear строки статуса уже отработал до доскролла и сам не повторится.
        .onChange(of: didInitialScroll) { done in
            if done, topVisible { requestOlder() }
        }
        // Страница пришла, а верх всё ещё виден (лента короче экрана) — грузим следующую.
        .onChange(of: store.loadingOlder) { loading in
            guard !loading else { return }
            if store.messages.first?.id == olderAnchorId { olderAnchorId = nil }
            if topVisible { requestOlder() }
        }
        // Открытие экрана. Одного `onChange` мало: `ChatStore` живёт в синглтоне
        // `MeerBot.shared` и переживает закрытие чата, поэтому при ПОВТОРНОМ открытии
        // список уже непустой, `messages.count` не меняется — и `onChange` не срабатывает
        // вовсе. Без этой ветки второй заход в чат всегда открывался сверху.
        .onAppear { jumpToBottom(proxy, animated: false) }
        // Ключ — ПОСЛЕДНЕЕ сообщение, а не их число: подгрузка старых сверху меняет число,
        // но не должна сбрасывать читающего историю вниз.
        .onChange(of: store.messages.last?.id) { _ in
            // Первый приход истории — мгновенно (экран должен ОТКРЫТЬСЯ внизу, а не
            // доехать туда); дальше новые сообщения — с анимацией, как в мессенджерах.
            jumpToBottom(proxy, animated: didInitialScroll)
        }
        // Лента едет ВМЕСТЕ с клавиатурой.
        //
        // SwiftUI меняет высоту окна, но ПРОКРУТКУ не трогает: на выезде нижние сообщения
        // уходят под поле ввода, на уходе лента остаётся задранной.
        //
        // Длительность берём из САМОГО уведомления, а не свою: чужой темп читается как рывок.
        // По той же причине едем на `willChangeFrame` — вместе с системной анимацией, а не
        // снапом после неё (`didChangeFrame`), который глаз ловит как скачок.
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification
        )) { note in
            guard let last = store.messages.last else { return }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                as? Double ?? 0.25
            didInitialScroll = true
            withAnimation(.easeOut(duration: duration)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            // Второй проход следующим тиком — из-за ПЕРВОГО показа клавиатуры. Уведомление
            // приходит до того, как вставка применена к списку, и первый `scrollTo` считает
            // по старой геометрии: лента и так внизу, делать ему нечего. Дальше содержимое
            // уезжает под клавиатуру и остаётся там — на втором и следующих показах геометрия
            // уже новая, поэтому баг ловился только на первом.
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: duration)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        #endif
    }

    /// Запросить старые. До первого доскролла вниз не грузим: на открытии верх виден всегда.
    /// После ошибки — только по «Повторить» (`force`), автоповтора нет.
    private func requestOlder(force: Bool = false) {
        guard didInitialScroll, store.hasOlder, !store.loadingOlder else { return }
        guard force || !store.olderFailed else { return }
        olderAnchorId = store.messages.first?.id
        onLoadOlder()
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

/// Содержимое ленты — отдельно от прокрутки, чтобы его можно было сравнить и не
/// пересобирать (см. `MessagesList.list`).
struct MessagesFeed: View, Equatable {
    let messages: [ChatMessage]
    let greeting: String?
    /// Состояние подгрузки старых — строка статуса над первым сообщением.
    let older: OlderHistoryState
    let onRetry: (String) -> Void
    /// Загрузчик картинок вложений. В сравнение не входит (замыкание), как и `onRetry`.
    let loadMedia: MediaLoader
    /// Верх ленты появился (`true`) / ушёл (`false`) с экрана. Замыкание — вне сравнения.
    let onTopVisible: (Bool) -> Void
    /// «Повторить» после ошибки подгрузки старых. Замыкание — вне сравнения.
    let onRetryOlder: () -> Void

    /// Сравнение — по данным ленты; замыкание повтора в него не входит (оно пересоздаётся на
    /// каждом кадре и сравнимым не бывает, а зовёт одно и то же).
    ///
    /// `nonisolated`: `Equatable` объявлен вне актора, и SwiftUI сравнивает вью там, где ему
    /// удобно. Без этого strict-concurrency видит обращение к `@MainActor`-состоянию из
    /// неизолированного контекста.
    nonisolated static func == (lhs: MessagesFeed, rhs: MessagesFeed) -> Bool {
        lhs.messages == rhs.messages && lhs.greeting == rhs.greeting && lhs.older == rhs.older
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            if messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(greeting ?? "Привет! Чем могу помочь?")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 40)
            } else {
                // Строка ВНУТРИ ленивого стека: её onAppear/onDisappear срабатывают по
                // видимости при прокрутке — это и есть сигнал «докрутили до начала».
                if older.hasOlder || older.failed {
                    OlderHistoryRow(state: older, onRetry: onRetryOlder)
                        .onAppear { onTopVisible(true) }
                        .onDisappear { onTopVisible(false) }
                }
                ForEach(messages) { msg in
                    MessageBubbleView(
                        message: msg,
                        // Повторяется только своё сообщение: у ответов ассистента повторять нечего.
                        onRetry: msg.role == "user" ? { onRetry(msg.id) } : nil,
                        loadMedia: loadMedia
                    )
                    .id(msg.id)
                }
            }
        }
    }
}

struct OlderHistoryState: Equatable {
    let hasOlder: Bool
    let loading: Bool
    let failed: Bool
}

/// Статус подгрузки старых над первым сообщением: спиннер, ошибка с «Повторить» или пусто.
struct OlderHistoryRow: View {
    let state: OlderHistoryState
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if state.loading {
                ProgressView()
                Text("Загружаем предыдущие сообщения…")
            } else if state.failed {
                Text("Не удалось загрузить предыдущие сообщения.")
                Button("Повторить", action: onRetry)
            }
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        // Пустая строка всё равно занимает высоту: иначе ленивому стеку нечего показывать,
        // и onAppear не срабатывает.
        .frame(maxWidth: .infinity, minHeight: 28)
        .padding(.vertical, 4)
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
    /// Отправка с вложениями. На платформах без выбора файлов (macOS) не вызывается.
    var onSendAttachments: (String, [OutgoingAttachment]) -> Void = { _, _ in }

    /// Выбранные, но ещё не отправленные файлы — показываются превью-чипами над полем.
    @State private var picks: [OutgoingAttachment] = []
    #if canImport(UIKit)
    /// Какой системный picker сейчас открыт (`nil` — закрыт).
    @State private var activePicker: AttachmentPickerKind?
    #endif

    /// Текст поля живёт в `ChatStore.draft`, а не в `@State` этого вью.
    ///
    /// Раньше здесь был свой `@State`, и `ChatStore.draft` не читал никто: смена identity
    /// чистила черновик стора, а поле — нет. Во встроенном чате (вкладка хоста, экран не
    /// закрывается) набранный, но не отправленный текст прежнего пользователя оставался в
    /// поле следующего, и тот мог отправить его в свой тред.
    /// Привязка, которую поле ввода получает В САМОМ вью: тест читает её отсюда, поэтому
    /// возврат текста в локальный `@State` роняет тест, а не проходит незамеченным.
    var draft: Binding<String> {
        Binding(get: { store.draft }, set: { store.setDraft($0) })
    }

    private var trimmed: String {
        store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var textField: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            TextField("Сообщение…", text: draft, axis: .vertical)
                .lineLimit(1...4)
        } else {
            TextField("Сообщение…", text: draft)
        }
    }

    /// Можно ли отправлять: есть текст ИЛИ вложение, и ничего сейчас не уходит.
    private var canSend: Bool {
        (!trimmed.isEmpty || !picks.isEmpty) && !store.sending && store.mode != .closed
    }

    var body: some View {
        VStack(spacing: 6) {
            if !picks.isEmpty {
                pickPreviews
            }
            HStack(spacing: 8) {
                #if canImport(UIKit)
                attachButton
                #endif
                // Многострочный ввод (`axis:`) появился только в iOS 16 — на iOS 15
                // остаётся однострочное поле, всё остальное поведение то же.
                textField
                    .focused($isFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.mbSurfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(store.mode == .closed)
                Button(action: sendTapped) {
                    Image(systemName: "paperplane.fill")
                        .padding(8)
                        .background(primaryColor)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Отправить")
            }
        }
        .padding(8)
        .background(Color.mbSurface)
        #if canImport(UIKit)
        .sheet(item: $activePicker) { kind in
            switch kind {
            case .media:
                MediaPicker(remaining: APIClient.maxAttachments - picks.count, onPicked: addPicks)
            case .file:
                DocumentPicker(onPicked: addPicks)
            }
        }
        #endif
    }

    /// Отправить: с вложениями — своим путём, без них — прежним. Текст и файлы уходят из
    /// композера вместе; ошибку доставки покажет уже лента (недоставленная строка).
    private func sendTapped() {
        guard canSend else { return }
        let text = trimmed
        if picks.isEmpty {
            store.clearDraft()
            onSend(text)
        } else {
            let files = picks
            store.clearDraft()
            picks = []
            onSendAttachments(text, files)
        }
    }

    /// Добавить выбранное, не превышая лимит. Отмена picker'а даёт пустой массив — no-op.
    private func addPicks(_ new: [OutgoingAttachment]) {
        guard !new.isEmpty else { return }
        let room = APIClient.maxAttachments - picks.count
        guard room > 0 else { return }
        picks.append(contentsOf: new.prefix(room))
    }

    /// Ряд превью выбранных файлов с кнопкой удаления у каждого.
    private var pickPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(picks.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 6) {
                        Image(systemName: mbAttachmentIcon(kind: item.kind))
                            .font(.system(size: 14))
                            .foregroundColor(primaryColor)
                        Text(item.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            picks.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Убрать вложение")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.mbSurfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: 180)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    #if canImport(UIKit)
    /// Скрепка: выбор «фото и видео» или «файл». Гаснет на закрытом диалоге и на лимите ≤10.
    private var attachButton: some View {
        Menu {
            Button {
                activePicker = .media
            } label: {
                Label("Фото и видео", systemImage: "photo")
            }
            Button {
                activePicker = .file
            } label: {
                Label("Файл", systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .padding(6)
        }
        .disabled(store.mode == .closed || picks.count >= APIClient.maxAttachments)
        .accessibilityLabel("Прикрепить файл")
    }
    #endif
}
