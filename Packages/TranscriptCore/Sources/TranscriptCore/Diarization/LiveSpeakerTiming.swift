import Foundation
import OSLog

/// Timing-only diagnostics: the closed stage vocabulary cannot carry user data.
public enum LiveSpeakerTiming {
    public enum Stage: String, Sendable {
        case recognitionAccepted
        case identityBinding
        case transactionCommit
        case projectionFetch
        case projectionDelivery
        case rowRendering
    }

    private static let logger = Logger(subsystem: "com.transcript", category: "LiveIdentityTiming")

    public static func record(_ stage: Stage, since started: ContinuousClock.Instant) {
        let elapsed = milliseconds(from: started, to: .now)
        let uptime = ProcessInfo.processInfo.systemUptime
        logger.debug("stage=\(stage.rawValue, privacy: .public) uptime_s=\(uptime, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)")
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return max(0, Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
    }
}
