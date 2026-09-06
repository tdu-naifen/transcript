import Foundation
import Observation

/// The app's own interface language (Settings → App Language). Independent of the
/// device system locale and unrelated to `AppServices.asrLanguage` (transcription
/// language, auto-detected by Nemotron) — the two must never be conflated.
enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case zhHans
    case en

    static let storageKey = "appLanguage"

    /// Backed directly by `UserDefaults` (thread-safe, no caching) so non-MainActor
    /// call sites can read the current selection without actor isolation.
    static var current: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    /// `nil` means "follow the device locale" — no override is applied.
    var locale: Locale? {
        switch self {
        case .system: nil
        case .zhHans: Locale(identifier: "zh-Hans")
        case .en: Locale(identifier: "en")
        }
    }

    /// Explicit languages name themselves; System follows the device, not the override.
    var displayName: String {
        switch self {
        case .system: String(localized: "System", locale: .autoupdatingCurrent)
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }
}

/// Drives live UI language switching without an app restart. `RootView` applies
/// `.environment(\.locale, ...)` from `language`, which SwiftUI's own `Text`/`Label`
/// (via `LocalizedStringKey`) pick up automatically. View models that pre-format
/// plain `String`s (not `LocalizedStringKey`) instead read `resolvedLocale` directly;
/// since that read happens synchronously inside a SwiftUI `body`, Observation still
/// tracks it and re-renders those views when `language` changes.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            AppLanguage.current = language
        }
    }

    var resolvedLocale: Locale {
        language.locale ?? .autoupdatingCurrent
    }

    var resolvedBundle: Bundle {
        guard let identifier = language.locale?.identifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    func text(_ key: String, table: String? = nil) -> String {
        localized(String.LocalizationValue(key), table: table)
    }

    // Foundation's locale argument formats values; the bundle selects the language.
    func localized(_ key: String.LocalizationValue, table: String? = nil) -> String {
        String(localized: key, table: table, bundle: resolvedBundle, locale: resolvedLocale)
    }

    private init() {
        language = AppLanguage.current
    }
}
