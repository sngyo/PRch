import Foundation
import SwiftUI
import ReviewCore

enum AppLanguage: String, CaseIterable {
    case system, japanese = "ja", english = "en"
    static var supportedCodes: [String] { allCases.filter { $0 != .system }.map(\.rawValue).sorted() }

    func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        return Bundle.preferredLocalizations(from: Self.supportedCodes, forPreferences: preferredLanguages).first ?? "en"
    }

    func title(in l10n: L10n) -> String {
        switch self {
        case .system: l10n.text("language.system")
        case .japanese: "日本語"
        case .english: "English"
        }
    }
}

/// UI strings use standard Apple localization resources. The selected bundle is
/// explicit so an in-app language change also updates AppKit labels and errors.
struct L10n {
    // App bundles and command-line SwiftPM builds have different layouts.
    static let resources = Bundle.main.url(forResource: "PRch_PRch", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module
    let code: String
    var locale: Locale { Locale(identifier: code) }
    private let bundle: Bundle
    private static let english = Bundle(url: resources.url(forResource: "en", withExtension: "lproj")!)!

    init(language: AppLanguage = .system, preferredLanguages: [String] = Locale.preferredLanguages) {
        code = language.resolvedCode(preferredLanguages: preferredLanguages)
        bundle = Self.resources.url(forResource: code, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? Self.english
    }

    func text(_ key: String, _ arguments: any CVarArg...) -> String {
        let fallback = Self.english.localizedString(forKey: key, value: key, table: nil)
        let format = bundle.localizedString(forKey: key, value: fallback, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    func error(_ error: ReviewError) -> String { text("error.\(error.rawValue)") }

    func warning(_ warning: ReviewWarning) -> String {
        guard let organization = warning.organization else { return error(warning.reason) }
        return text("warning.organization", organization, error(warning.reason))
    }

    func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return text("time.now") }
        var components = DateComponents()
        if seconds < 3_600 { components.minute = -Int(seconds / 60) }
        else if seconds < 86_400 { components.hour = -Int(seconds / 3_600) }
        else { components.day = -Int(seconds / 86_400) }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(from: components)
    }
}

private struct LocalizationKey: EnvironmentKey {
    static let defaultValue = L10n()
}

extension EnvironmentValues {
    var l10n: L10n {
        get { self[LocalizationKey.self] }
        set { self[LocalizationKey.self] = newValue }
    }
}
