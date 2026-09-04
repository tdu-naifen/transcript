import Foundation
import SwiftUI
import TranscriptCore

enum Format {
    /// mm:ss, or h:mm:ss past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    static func duration(milliseconds: Int) -> String {
        clock(Double(milliseconds) / 1000)
    }

    static func bytes(_ count: Int?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatStyle(style: .file).format(Int64(count))
    }

    static func shortHash(_ hash: String?) -> String {
        guard let hash, hash.count > 12 else { return hash ?? "—" }
        return "\(hash.prefix(8))…\(hash.suffix(4))"
    }
}

extension MeetingState {
    var label: String {
        switch self {
        case .recording: "Recording"
        case .recorded: "Recorded"
        case .audioSynced: "Synced"
        case .queued: "Queued"
        case .analyzing: "Analyzing"
        case .analyzed: "Analyzed"
        case .failed: "Needs attention"
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
