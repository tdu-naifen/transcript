import Foundation
import GRDB

/// PLAN §5.1 / §10: Nemotron is the only engine; there is no Apple `SpeechTranscriber`
/// fallback. Kept as an enum because a second engine is plausible later.
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    case nemotron
}

/// Layer B: append-only transcript segment, written only by the iPhone.
public struct Utterance: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var meetingId: String
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var speakerId: String?
    /// BCP-47 tag detected by Nemotron for this segment (`<en-US>`). This is the
    /// truth for language; `meeting.localeIdentifier` is only a summary (PLAN §9.2).
    public var localeIdentifier: String?
    public var confidence: Double?
    public var engine: TranscriptionEngine
    /// Monotonic per-record version (PLAN §3.2 single-writer versioning).
    public var revision: Int
    public var createdAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var updatedAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var originDeviceId: String

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        startMs: Int,
        endMs: Int,
        text: String,
        speakerId: String? = nil,
        localeIdentifier: String? = nil,
        confidence: Double? = nil,
        engine: TranscriptionEngine = .nemotron,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceId: String
    ) {
        self.id = id
        self.meetingId = meetingId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
        self.localeIdentifier = localeIdentifier
        self.confidence = confidence
        self.engine = engine
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
    }
}

extension Utterance: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "utterance"

    public enum Columns {
        public static let id = Column("id")
        public static let meetingId = Column("meetingId")
        public static let startMs = Column("startMs")
        public static let speakerId = Column("speakerId")
        public static let localeIdentifier = Column("localeIdentifier")
        public static let revision = Column("revision")
        public static let updatedAt = Column("updatedAt")
    }
}
