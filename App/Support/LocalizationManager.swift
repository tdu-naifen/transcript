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

    /// Fixed, not translated — each option names itself in its own language, the same
    /// convention Apple uses for its own language pickers.
    var displayName: String {
        switch self {
        case .system: "跟随系统"
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

    private init() {
        language = AppLanguage.current
    }
}
