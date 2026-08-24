// MeerBot iOS SDK — единственное место, где различаются UIKit и AppKit.
//
// Нужно ради `swift build`/`swift test` на macOS-хосте (CI без симулятора): системные цвета
// UIKit на macOS не существуют. Продуктовая площадка — iOS, macOS-срез только собирается.

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

extension Color {

    /// Фон экрана чата.
    static var mbSurface: Color {
        #if canImport(UIKit)
        return Color(.systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Фон поля ввода и пузыря собеседника.
    static var mbSurfaceSecondary: Color {
        #if canImport(UIKit)
        return Color(.secondarySystemBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

/// Тактильный отклик. Живёт здесь по той же причине, что и цвета: `UIImpactFeedbackGenerator`
/// — UIKit, а пакет обязан собираться и под macOS (CI без симулятора).
enum MBHaptics {

    /// Лёгкий отклик на нажатие — тот же вес, что хост-приложения ставят на строки меню и
    /// кнопки навигации. Сильнее здесь не нужно: закрытие чата не разрушительное действие.
    @MainActor
    static func lightImpact() {
        #if canImport(UIKit) && !os(watchOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        // `prepare()` перед срабатыванием: без него первый отклик в сессии приходит с
        // задержкой в те же ~100 мс, за которые экран уже закрывается, — и ощущается как
        // «хаптика нет».
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}
