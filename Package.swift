// swift-tools-version:5.9
// MeerBot iOS SDK — Phase 5 (Plan v2 ADR-003 triple-native).
// Native iOS SDK с SwiftUI UI + native bridges (APNs, Keychain, App Attest, cert pinning).
//
// Public API contract (см. docs/mobile-sdk/api-reference.md) идентичен Android и RN
// для cross-platform consistency. Изменения контракта требуют синхронной правки во всех трёх SDK.

import PackageDescription

let package = Package(
    name: "MeerBotSDK",
    platforms: [
        .iOS(.v15) // iOS 15+ для SwiftUI + App Attest
    ],
    products: [
        .library(
            name: "MeerBotSDK",
            targets: ["MeerBotSDK"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MeerBotSDK",
            dependencies: [],
            path: "Sources/MeerBotSDK"
        ),
        .testTarget(
            name: "MeerBotSDKTests",
            dependencies: ["MeerBotSDK"],
            path: "Tests/MeerBotSDKTests"
        )
    ]
)
