// Демонстрационное приложение MeerBot SDK.
// Как запустить — см. Example/README.md рядом.

import SwiftUI
import MeerBotSDK

@main
struct MeerBotDemoApp: App {

    init() {
        // Ключ headless-виджета из кабинета: Бот → Каналы → Виджеты.
        // В демо читаем из Info.plist, чтобы ключ не лежал в исходниках.
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "MeerBotApiKey") as? String ?? ""
        guard !apiKey.isEmpty else {
            print("[demo] не задан MeerBotApiKey в Info.plist — чат покажет экран «не настроен»")
            return
        }
        MeerBot.shared.configure(apiKey: apiKey)
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ReadyScreenDemo()
                    .tabItem { Label("Готовый экран", systemImage: "bubble.left.and.bubble.right") }
                CustomChatDemo()
                    .tabItem { Label("Свой UI", systemImage: "paintbrush") }
            }
        }
    }
}
