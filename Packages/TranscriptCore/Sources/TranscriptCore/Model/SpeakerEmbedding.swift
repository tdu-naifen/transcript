import Foundation
import GRDB

/// Voiceprint vector. Brute-force cosine is fine at this scale (PLAN §4.4) —
/// deliberately no vector index.
public struct SpeakerEmbedding: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var speakerId: String
    /// Raw little-endian Float32, see `FloatVector`.
    public var vector: Data
    public var dimension: Int
    public var sampleCount: Int
    public var createdAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.3). `mergeSpeakers` mutates this row.
    public var updatedAt: Date
    /// Reserved for a future HLC retrofit (PLAN §9.3). `mergeSpeakers` mutates this row.
    public var originDeviceId: String

    public init(
        id: String = UUID().uuidString,
        speakerId: String,
        vector: Data,
        dimension: Int,
        sampleCount: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceId: String
    ) {
        self.id = id
        self.speakerId = speakerId
        self.vector = vector
        self.dimension = dimension
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
    }

    public init(
        id: String = UUID().uuidString,
        speakerId: String,
        floats: [Float],
        sampleCount: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceId: String
    ) {
        self.init(
            id: id,
            speakerId: speakerId,
            vector: FloatVector.data(from: floats),
            dimension: floats.count,
            sampleCount: sampleCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            originDeviceId: originDeviceId
        )
    }

    public var floats: [Float] { FloatVector.floats(from: vector) }
}

extension SpeakerEmbedding: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speakerEmbedding"

    public enum Columns {
        public static let id = Column("id")
        public static let speakerId = Column("speakerId")
    }
}
