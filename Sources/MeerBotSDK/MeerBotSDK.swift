// MeerBot iOS SDK — Public API entry point.
// Phase 5 scaffolding. Полная имплементация — Phase 5.b (Sources/MeerBotSDK/UI/*).

import Foundation
import SwiftUI

public enum MeerBotPlatform {
    public static let version = "0.1.0-alpha"
    public static let apiBaseUrl = "https://meerbot.ru"
}

/// Public API контракт идентичен Android + RN (см. docs/mobile-sdk/api-reference.md).
@MainActor
public final class MeerBot {

    public static let shared = MeerBot()

    private var apiKey: String?
    private var visitorUuid: String?
    private var jwt: String?
    private var jwtExpiresAt: Date?

    private init() {}

    /// Configure SDK с published mobile app credentials.
    /// - Parameters:
    ///   - apiKey: pk_live_* из /cabinet/integrations/mobile в кабинете владельца app.
    ///   - userId: опциональный external user id (HMAC-signed на backend) для idenfication.
    public func configure(apiKey: String, userId: String? = nil) {
        self.apiKey = apiKey
        self.visitorUuid = Self.getOrCreateVisitorUuid()
        // TODO Phase 5.b: register device через POST /api/v1/mobile/register
        // TODO Phase 5.b: bootstrap JWT + start App Attest verification
    }

    /// Открыть chat UI (SwiftUI sheet или fullScreenCover).
    /// Возвращает SwiftUI View — caller присоединяет к своему view hierarchy.
    public func chatView() -> some View {
        ChatPlaceholderView()
    }

    /// Register для push notifications. Caller должен сначала запросить разрешение
    /// у пользователя через UNUserNotificationCenter.
    public func setPushToken(_ deviceToken: Data) {
        // TODO Phase 5.b: convert Data → hex string + POST /api/v1/mobile/register
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[MeerBot] APNs token registered: \(hex.prefix(12))...")
    }

    /// Handle incoming push notification (вызывается из AppDelegate / SceneDelegate).
    public func handlePush(_ payload: [AnyHashable: Any]) -> Bool {
        guard let conversationId = payload["conversationId"] as? Int else { return false }
        // TODO Phase 5.b: deep link в ChatView с conversationId
        print("[MeerBot] push for conversation \(conversationId)")
        return true
    }

    /// Reset SDK state — для GDPR Art. 17 invocation на client side.
    public func reset() {
        self.apiKey = nil
        self.visitorUuid = nil
        self.jwt = nil
        self.jwtExpiresAt = nil
        UserDefaults.standard.removeObject(forKey: "meerbot.visitorUuid")
        // TODO Phase 5.b: secure delete JWT из Keychain
    }

    // MARK: - Helpers

    private static func getOrCreateVisitorUuid() -> String {
        if let stored = UserDefaults.standard.string(forKey: "meerbot.visitorUuid") {
            return stored
        }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: "meerbot.visitorUuid")
        return new
    }
}

/// Placeholder для Phase 5.b implementation. Реальная UI — SwiftUI ChatView с
/// MessagesList, MessageBubble, Input, TypingIndicator (см. Plan v2 Phase 5.b).
struct ChatPlaceholderView: View {
    var body: some View {
        VStack {
            Text("MeerBot Chat")
                .font(.headline)
            Text("Phase 5.b UI implementation pending")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding()
    }
}
