import Foundation
import GRDB

/// Keep the legacy engine value readable for existing meetings.
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    case nemotron
    case appleSpeech
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

    public init(
        meetingId: String,
        speakerId: String?,
        startMs: Int,
        endMs: Int,
        text: String,
        originDeviceId: String
    ) {
        self.init(
            meetingId: meetingId, startMs: startMs, endMs: endMs, text: text,
            speakerId: speakerId, originDeviceId: originDeviceId
        )
    }
}

extension Utterance: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "utterance"
    public static var databaseSelection: [any SQLSelectable] {
        [AllColumnsExcluding(["text"]), SQL("CAST(text AS BLOB) AS text")]
    }

    public init(row: Row) throws {
        let bytes: Data = row["text"]
        guard let engine = TranscriptionEngine(rawValue: row["engine"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown transcription engine"))
        }
        self.init(id: row["id"], meetingId: row["meetingId"], startMs: row["startMs"],
            endMs: row["endMs"], text: String(decoding: bytes, as: UTF8.self),
            speakerId: row["speakerId"], localeIdentifier: row["localeIdentifier"],
            confidence: row["confidence"], engine: engine,
            revision: row["revision"], createdAt: row["createdAt"], updatedAt: row["updatedAt"],
            originDeviceId: row["originDeviceId"])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["meetingId"] = meetingId
        container["startMs"] = startMs
        container["endMs"] = endMs
        // Older GRDB versions bind String with a C-string length. A UTF-8 blob
        // preserves embedded NULs and still decodes as String on both versions.
        container["text"] = text.contains("\0") ? Data(text.utf8).databaseValue : text.databaseValue
        container["speakerId"] = speakerId
        container["localeIdentifier"] = localeIdentifier
        container["confidence"] = confidence
        container["engine"] = engine.rawValue
        container["revision"] = revision
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
        container["originDeviceId"] = originDeviceId
    }

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
