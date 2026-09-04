import Foundation

/// Lifecycle of a recording (PLAN §3.2.1).
///
/// `recording → recorded → audioSynced → queued → analyzing → analyzed`
///
/// Nemotron is a streaming engine, so capture, transcription and diarization all
/// happen inside `recording`; there is no separate transcribe phase.
/// `analyzed` is not terminal (`analyzed → queued` re-runs analysis) and neither is
/// `failed` — a failed meeting resumes from `Meeting.failedFromState`.
public enum MeetingState: String, Codable, Sendable, CaseIterable {
    /// Audio capture + live transcription + live diarization, all at once.
    case recording
    /// Capture stopped; the transcript is already complete.
    case recorded
    case audioSynced
    case queued
    case analyzing
    case analyzed
    case failed

    /// Successors reachable without knowing where a failure came from.
    /// `failed` is empty here because its successors depend on `failedFromState`;
    /// use ``allowedNextStates(failedFrom:)``.
    public var allowedNextStates: Set<MeetingState> {
        switch self {
        case .recording: [.recorded, .failed]
        case .recorded: [.audioSynced, .failed]
        case .audioSynced: [.queued, .failed]
        case .queued: [.analyzing, .failed]
        case .analyzing: [.analyzed, .failed]
        case .analyzed: [.queued, .failed]
        case .failed: []
        }
    }

    /// A `failed` row whose origin was never recorded still has to be recoverable:
    /// PLAN §3.2.1 has no terminal state and losing a meeting is unacceptable, so an
    /// unknown origin is treated as `recording` — the earliest stage, from which the
    /// partial audio and transcript can be salvaged as a short meeting.
    public static let failedOriginFallback: MeetingState = .recording

    /// Retry out of `failed` may either resume the state that failed or move
    /// forward to one of that state's successors.
    public func allowedNextStates(failedFrom: MeetingState?) -> Set<MeetingState> {
        guard self == .failed else { return allowedNextStates }
        let origin = (failedFrom == .failed ? nil : failedFrom) ?? Self.failedOriginFallback
        return origin.allowedNextStates.subtracting([.failed]).union([origin])
    }

    public func canTransition(to next: MeetingState) -> Bool {
        allowedNextStates.contains(next)
    }

    public func canTransition(to next: MeetingState, failedFrom: MeetingState?) -> Bool {
        allowedNextStates(failedFrom: failedFrom).contains(next)
    }
}

public struct IllegalMeetingStateTransition: Error, Sendable, Equatable {
    public let from: MeetingState
    public let to: MeetingState
    public let failedFrom: MeetingState?

    public init(from: MeetingState, to: MeetingState, failedFrom: MeetingState? = nil) {
        self.from = from
        self.to = to
        self.failedFrom = failedFrom
    }
}
