import Foundation

/// Shared duration formatting for the live recording timer and the recordings list.
/// Localized via this package's own `en.lproj`/`zh-Hans.lproj` resources
/// (`Bundle.module`), since `TranscriptCore` ships independently of the app's own
/// String Catalog. Classic `.strings` rather than a `.xcstrings` catalog: plain
/// `swift build`/`swift test` (no Xcode build system) only copies `.xcstrings`
/// resources verbatim without compiling them, so `Bundle.localizedString` would
/// never see translations — `.lproj` lookup works identically under both.
public enum DurationFormat {
    /// mm:ss, or h:mm:ss past an hour. Digits only, so this is locale-invariant.
    public static func clock(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Disambiguates magnitude at a glance: sub-minute durations render as "5s"/"5秒"
    /// instead of "00:05", which looks identical in shape to a minutes-scale duration.
    public static func label(milliseconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        guard totalSeconds < 60 else { return clock(seconds: Double(milliseconds) / 1000) }
        let format = localizedBundle(for: locale)
            .localizedString(forKey: "duration_seconds", value: "%llds", table: nil)
        return String(format: format, totalSeconds)
    }

    /// Bare `Bundle.localizedString` picks a language from the *process's* preferred
    /// languages, ignoring any `locale` argument — so in-app language switching needs
    /// to look up the matching `.lproj` sub-bundle explicitly instead. SwiftPM lowercases
    /// `.lproj` directory names when copying resources, so the lookup must too.
    private static func localizedBundle(for locale: Locale) -> Bundle {
        let candidates = [locale.identifier, locale.language.languageCode?.identifier].compactMap { $0 }
        for candidate in candidates {
            for name in [candidate, candidate.lowercased()] {
                if let path = Bundle.module.path(forResource: name, ofType: "lproj"),
                   let bundle = Bundle(path: path) {
                    return bundle
                }
            }
        }
        return Bundle.module
    }
}
