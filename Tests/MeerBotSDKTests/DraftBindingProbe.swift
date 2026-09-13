// Доступ к привязке текста поля ввода ИЗ САМОГО вью.
//
// Тесты черновика обязаны падать, если текст вернут в локальный `@State` вью: поэтому они
// читают привязку у настоящего экземпляра `ChatInput`, а не у отдельного помощника, который
// в этом случае продолжал бы отвечать правильно, пока поле живёт своей жизнью.

import SwiftUI
@testable import MeerBotSDK

@MainActor
func draftBindingOfChatInput(_ store: ChatStore) -> Binding<String> {
    var focus = FocusState<Bool>()
    let input = ChatInput(
        store: store,
        primaryColor: .blue,
        isFocused: focus.projectedValue,
        onSend: { _ in }
    )
    return input.draft
}
