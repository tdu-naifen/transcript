import Foundation

public enum RepositoryError: Error, Sendable, Equatable {
    case notFound(table: String, id: String)
    /// `markLocalAudioPurged` was called before the Mac confirmed its SHA-256 check
    /// (PLAN §3.4). "Bytes transferred" is not enough to delete the only copy.
    case audioNotVerifiedOnMac(meetingId: String)
    case dimensionMismatch(expected: Int, actual: Int)
    case cannotMergeSpeakerIntoItself(speakerId: String)
    /// Two speakers were mapped onto the same `displayIndex` in one remap. Rejected
    /// up front so the caller sees the real mistake instead of a UNIQUE violation.
    case duplicateDisplayIndex(meetingId: String, displayIndex: Int)
    /// `displayIndex` is a user-facing "Speaker N" label and must be non-negative;
    /// negative values are reserved for parking rows mid-remap.
    case negativeDisplayIndex(meetingId: String, displayIndex: Int)
    case unknownAnalysisKind(rawValue: String)
}
