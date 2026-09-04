import Foundation

/// Shared duration formatting for the live recording timer and the recordings list.
public enum DurationFormat {
    /// mm:ss, or h:mm:ss past an hour.
    public static func clock(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Disambiguates magnitude at a glance: sub-minute durations render as "N秒"
    /// instead of "00:0N", which looks identical in shape to a minutes-scale duration.
    public static func label(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        guard totalSeconds >= 60 else { return "\(totalSeconds)秒" }
        return clock(seconds: Double(milliseconds) / 1000)
    }
}
