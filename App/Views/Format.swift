import Foundation
import SwiftUI
import TranscriptCore

/// Plain-`String` producing helpers, consumed via SwiftUI's non-localizing "verbatim"
/// overloads (`Text(_ s: String)`, `LabeledContent(_:value: String)`, ...) — so each
/// function resolves `LocalizationManager.shared.resolvedLocale` itself rather than
/// relying on `.environment(\.locale)`. Reading that singleton happens synchronously
/// inside whichever SwiftUI `body` calls these, so Observation still re-renders when
/// the user changes the app language, even though the value isn't a `LocalizedStringKey`.
@MainActor
enum Format {
    /// mm:ss, or h:mm:ss past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        DurationFormat.clock(seconds: seconds)
    }

    /// Disambiguates seconds from minutes (UI.md row durations); see `DurationFormat`.
    static func duration(milliseconds: Int) -> String {
        DurationFormat.label(milliseconds: milliseconds, locale: LocalizationManager.shared.resolvedLocale)
    }

    static func bytes(_ count: Int?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatStyle(style: .file)
            .locale(LocalizationManager.shared.resolvedLocale)
            .format(Int64(count))
    }

    static func shortHash(_ hash: String?) -> String {
        guard let hash, hash.count > 12 else { return hash ?? "—" }
        return "\(hash.prefix(8))…\(hash.suffix(4))"
    }

    /// Requirement: dates in the UI follow the *selected app language*, not just the
    /// device locale (so switching the in-app picker also re-renders these).
    static func date(
        _ date: Date,
        dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
        timeStyle: Date.FormatStyle.TimeStyle = .shortened
    ) -> String {
        date.formatted(
            Date.FormatStyle(date: dateStyle, time: timeStyle)
                .locale(LocalizationManager.shared.resolvedLocale)
        )
    }
}

extension MeetingState {
    @MainActor
    var label: String {
        let locale = LocalizationManager.shared.resolvedLocale
        switch self {
        case .recording: return String(localized: "Recording", locale: locale)
        case .recorded: return String(localized: "Recorded", locale: locale)
        case .audioSynced: return String(localized: "Synced", locale: locale)
        case .queued: return String(localized: "Queued", locale: locale)
        case .analyzing: return String(localized: "Analyzing", locale: locale)
        case .analyzed: return String(localized: "Analyzed", locale: locale)
        case .failed: return String(localized: "Needs attention", locale: locale)
        }
    }

    var tint: Color {
        switch self {
        case .recording: .red
        case .recorded: .blue
        case .audioSynced, .queued: .teal
        case .analyzing: .purple
        case .analyzed: .green
        case .failed: .orange
        }
    }
}

extension Color {
    /// A stable palette for `Speaker.colorIndex` (UI.md §4.4): the same index always maps
    /// to the same color, independent of name or display order.
    private static let speakerPalette: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown
    ]

    static func speaker(colorIndex: Int) -> Color {
        let count = speakerPalette.count
        return speakerPalette[((colorIndex % count) + count) % count]
    }
}
