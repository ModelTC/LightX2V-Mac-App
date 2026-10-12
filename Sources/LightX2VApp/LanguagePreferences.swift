import Foundation
import SwiftUI
import LightX2VCore

@MainActor
final class LanguagePreferences: ObservableObject {
    static let shared = LanguagePreferences()
    static let options: [(code: String, name: String)] = [
        ("system", "System"), ("en", "English"), ("zh-Hans", "简体中文"), ("fr", "Français"),
        ("ja", "日本語"), ("ko", "한국어"), ("de", "Deutsch"), ("ru", "Русский"),
        ("es", "Español"), ("pt", "Português"), ("ar", "العربية")
    ]
    private let defaults: UserDefaults
    @Published var selection: String {
        didSet {
            defaults.set(selection, forKey: "interfaceLanguage")
            L10n.languageCode = resolvedCode
        }
    }
    var resolvedCode: String { selection == "system" ? L10n.resolve(Locale.preferredLanguages) : selection }
    var locale: Locale { Locale(identifier: resolvedCode) }
    var direction: LayoutDirection { resolvedCode == "ar" ? .rightToLeft : .leftToRight }
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ProcessInfo.processInfo.environment["LIGHTX2V_APP_PREFERENCES_SUITE"]
            .flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let saved = self.defaults.string(forKey: "interfaceLanguage") ?? "system"
        selection = Self.options.contains { $0.code == saved } ? saved : "system"
        L10n.languageCode = resolvedCode
    }
}
