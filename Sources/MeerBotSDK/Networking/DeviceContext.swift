// MeerBot iOS SDK — device-context для тела `register`.
//
// `model`/`osVersion` — через `UIDevice`, которого на macOS-хосте (CI без симулятора,
// см. `Support/PlatformAppearance.swift`) не существует; там эти два поля просто не
// собираются, а не подставляются заглушкой.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Диагностический снимок устройства, уходящий в `POST /api/v1/mobile/register` вложенным
/// `device`. Каждое поле — необязательное и по отдельности: сервер получает то, что удалось
/// собрать, а не забраковывает всё тело из-за одного отсутствующего значения.
enum DeviceContext {

    /// Контрактный предел на значение (как у `sdkVersion` в `RegisterSchema` бэкенда) —
    /// длинная строка от нестандартной прошивки/локали не должна раздувать тело запроса.
    private static let maxFieldLength = 64

    /// Собрать словарь для тела `register`. Пустой словарь — вызывающий не кладёт ключ
    /// `device` вовсе (см. `APIClient.register()`).
    static func collect(config: MeerBotConfiguration) -> [String: String] {
        var device: [String: String] = [:]

        // Хост может знать свою версию/сборку точнее (например, из своего CI) — его значение
        // побеждает; иначе берём то, что реально зашито в бандл.
        if let appVersion = sanitize(config.appVersion ?? bundleAppVersion) {
            device["appVersion"] = appVersion
        }
        if let appBuild = sanitize(config.appBuild ?? bundleAppBuild) {
            device["appBuild"] = appBuild
        }
        if let model = sanitize(deviceModel) {
            device["model"] = model
        }
        if let osVersion = sanitize(systemVersion) {
            device["osVersion"] = osVersion
        }
        if let locale = sanitize(Locale.current.identifier) {
            device["locale"] = locale
        }
        if let timezone = sanitize(TimeZone.current.identifier) {
            device["timezone"] = timezone
        }

        return device
    }

    private static var bundleAppVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var bundleAppBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    private static var deviceModel: String? {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return nil
        #endif
    }

    private static var systemVersion: String? {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return nil
        #endif
    }

    /// Обрезка до предела и отбрасывание пустого значения. Пустая строка после обрезки
    /// пробелов для сервера неотличима от отсутствующего поля — класть её незачем.
    private static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxFieldLength))
    }
}
