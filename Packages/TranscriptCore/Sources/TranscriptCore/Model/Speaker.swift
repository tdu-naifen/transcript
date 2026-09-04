import Foundation
import GRDB

/// A person, stable across meetings (PLAN Phase 0d / §3.1.1).
/// `id` never changes; only the per-meeting `displayIndex` is remapped, and naming a
/// speaker once applies to every meeting that references the id.
public struct Speaker: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String?
    public var anonymousName: String
    public var colorIndex: Int
    public var createdAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var updatedAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var originDeviceId: String

    public init(
        id: String = UUID().uuidString,
        displayName: String? = nil,
        anonymousName: String,
        colorIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceId: String
    ) {
        self.id = id
        self.displayName = displayName
        self.anonymousName = anonymousName
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
    }

    public var resolvedName: String { displayName ?? anonymousName }
}

extension Speaker: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker"

    public enum Columns {
        public static let id = Column("id")
        public static let displayName = Column("displayName")
        public static let anonymousName = Column("anonymousName")
        public static let updatedAt = Column("updatedAt")
    }
}

/// Join table carrying the "Speaker 1 / 2 / 3" label shown inside one meeting.
/// Written by the iPhone only, from on-device live diarization (PLAN §3.1 Layer C).
public struct MeetingSpeaker: Codable, Hashable, Sendable {
    public var meetingId: String
    public var speakerId: String
    public var displayIndex: Int
    public var createdAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var updatedAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.1).
    public var originDeviceId: String

    public init(
        meetingId: String,
        speakerId: String,
        displayIndex: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceId: String
    ) {
        self.meetingId = meetingId
        self.speakerId = speakerId
        self.displayIndex = displayIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
    }
}

extension MeetingSpeaker: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetingSpeaker"

    public enum Columns {
        public static let meetingId = Column("meetingId")
        public static let speakerId = Column("speakerId")
        public static let displayIndex = Column("displayIndex")
    }
}
