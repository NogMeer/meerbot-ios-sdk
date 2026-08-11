// swift-tools-version:5.9
// MeerBot iOS SDK — Swift Package.
//
// Продуктовая платформа — iOS 15+. macOS 12 объявлен ТОЛЬКО чтобы `swift build`/`swift test`
// работали на хосте без симулятора (CI + локальный прогон): весь UIKit-специфичный код
// изолирован в Support/PlatformAppearance.swift. Поддерживаемая площадка — iOS.
//
// Публичный API-контракт: docs/mobile-sdk/api-reference.md. Изменения контракта требуют
// синхронной правки Android/RN SDK.

import PackageDescription

let package = Package(
    name: "MeerBotSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
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
            path: "Sources/MeerBotSDK",
            resources: [
                // App Store (iOS 17+) требует privacy manifest внутри бандла SDK.
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "MeerBotSDKTests",
            dependencies: ["MeerBotSDK"],
            path: "Tests/MeerBotSDKTests"
        ),
    ]
)
