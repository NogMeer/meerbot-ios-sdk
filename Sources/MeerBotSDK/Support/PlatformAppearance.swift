// MeerBot iOS SDK — единственное место, где различаются UIKit и AppKit.
//
// Нужно ради `swift build`/`swift test` на macOS-хосте (CI без симулятора): системные цвета
// UIKit на macOS не существуют. Продуктовая площадка — iOS, macOS-срез только собирается.

import SwiftUI

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
