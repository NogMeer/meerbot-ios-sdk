// Вариант 1 — готовый экран SDK, минимальная интеграция.

import SwiftUI
import MeerBotSDK

struct ReadyScreenDemo: View {
    @State private var showChat = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Экран приложения")
                .font(.title2)
            Text("Кнопка ниже открывает готовый экран чата из SDK — это вся интеграция.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Поддержка") { showChat = true }
                .buttonStyle(.borderedProminent)
                // Прогрев сессии по наведению/появлению кнопки — экран откроется без паузы.
                .onAppear { MeerBot.shared.preconnect() }
        }
        .sheet(isPresented: $showChat) {
            MeerBot.shared.chatView(title: "Поддержка", primaryColor: .accentColor) {
                showChat = false
            }
        }
    }
}
