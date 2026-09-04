import Foundation
import GRDB

/// Layer A/B owner record. Written only by the iPhone (PLAN §3.1).
public struct Meeting: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var durationMs: Int
    /// Denormalized "primary language" summary; the truth is `utterance.localeIdentifier`
    /// (PLAN §9.2). Derive it with `MeetingRepository.refreshPrimaryLanguage`.
    public var localeIdentifier: String?
    public var audioFileName: String?
    public var audioSHA256: String?
    public var audioByteCount: Int?
    /// Only ``MeetingRepository/transition(id:to:deviceId:now:)`` may move this, so the
    /// `(state, failedFromState)` pair cannot be broken apart from outside the module.
    public internal(set) var state: MeetingState
    /// State this meeting failed from, so a retry can resume (PLAN §3.2.1).
    /// Never nil while `state == .failed`: the pair is normalized by ``init`` and
    /// enforced by a CHECK constraint on the `meeting` table.
    public internal(set) var failedFromState: MeetingState?
    /// Bytes finished transferring. Written by the iPhone (the sender).
    public var syncedToMacAt: Date?
    /// Mac re-hashed the landed file and SHA-256 matched. Written by the Mac and sent
    /// back to the iPhone. The only gate that permits deleting local audio (PLAN §3.4).
    public var audioVerifiedOnMacAt: Date?
    public var localAudioPurgedAt: Date?
    public var createdAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var updatedAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var originDeviceId: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        startedAt: Date,
        durationMs: Int = 0,
        localeIdentifier: String? = nil,
        audioFileName: String? = nil,
        audioSHA256: String? = nil,
        audioByteCount: Int? = nil,
        state: MeetingState = .recording,
        failedFromState: MeetingState? = nil,
        syncedToMacAt: Date? = nil,
        audioVerifiedOnMacAt: Date? = nil,
        localAudioPurgedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceId: String
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.localeIdentifier = localeIdentifier
        self.audioFileName = audioFileName
        self.audioSHA256 = audioSHA256
        self.audioByteCount = audioByteCount
        self.state = state
        self.failedFromState = Self.normalizedFailedFromState(state: state, failedFromState: failedFromState)
        self.syncedToMacAt = syncedToMacAt
        self.audioVerifiedOnMacAt = audioVerifiedOnMacAt
        self.localAudioPurgedAt = localAudioPurgedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
    }

    /// `failed` with no origin would be unrecoverable, so it is not constructible:
    /// a missing origin becomes ``MeetingState/failedOriginFallback``, and an origin
    /// recorded on a non-failed state is dropped.
    static func normalizedFailedFromState(
        state: MeetingState,
        failedFromState: MeetingState?
    ) -> MeetingState? {
        guard state == .failed else { return nil }
        let origin = failedFromState == .failed ? nil : failedFromState
        return origin ?? MeetingState.failedOriginFallback
    }
}

extension Meeting: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting"

    public enum Columns {
        public static let id = Column("id")
        public static let title = Column("title")
        public static let startedAt = Column("startedAt")
        public static let state = Column("state")
        public static let failedFromState = Column("failedFromState")
        public static let syncedToMacAt = Column("syncedToMacAt")
        public static let audioVerifiedOnMacAt = Column("audioVerifiedOnMacAt")
        public static let localAudioPurgedAt = Column("localAudioPurgedAt")
        public static let updatedAt = Column("updatedAt")
    }
}
