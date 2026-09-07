import Foundation
import GRDB

public struct ReprocessedUtteranceDraft: Sendable, Equatable {
    public var id: String
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var speakerIndex: Int?
    public var localeIdentifier: String?
    public var confidence: Double?

    public init(
        id: String = UUID().uuidString,
        startMs: Int,
        endMs: Int,
        text: String,
        speakerIndex: Int? = nil,
        localeIdentifier: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerIndex = speakerIndex
        self.localeIdentifier = localeIdentifier
        self.confidence = confidence
    }
}

public struct ReprocessedSpeakerDraft: Sendable, Equatable {
    public var speakerIndex: Int
    public var existingSpeakerId: String?
    public var embedding: [Float]?
    public var wasVoiceprintMatch: Bool

    public init(
        speakerIndex: Int,
        existingSpeakerId: String? = nil,
        embedding: [Float]? = nil,
        wasVoiceprintMatch: Bool = false
    ) {
        self.speakerIndex = speakerIndex
        self.existingSpeakerId = existingSpeakerId
        self.embedding = embedding
        self.wasVoiceprintMatch = wasVoiceprintMatch
    }
}

public struct MeetingReprocessingResult: Sendable, Equatable {
    public let utteranceCount: Int
    public let speakerCount: Int
}

public struct MeetingReprocessingSnapshot: Sendable {
    public let audioSHA256: String?
    public let utterances: [Utterance]
    public init(audioSHA256: String?, utterances: [Utterance]) {
        self.audioSHA256 = audioSHA256
        self.utterances = utterances
    }
}

public enum MeetingReprocessingSnapshotError: Error { case changed }
public enum MeetingReprocessingTimingError: Error, Sendable { case invalidRange }

public struct MeetingReprocessingRepository: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// Atomically replaces derived transcript and meeting-speaker rows. Voiceprint
    /// embeddings are evidence only and are never enrolled by this operation.
    /// Cancellation observed before the final transaction check rolls back all changes;
    /// after that check, the atomic commit wins.
    @discardableResult
    public func replace(
        meetingId: String,
        utterances drafts: [ReprocessedUtteranceDraft],
        speakers speakerDrafts: [ReprocessedSpeakerDraft],
        deviceId: String,
        engine: TranscriptionEngine = .nemotron,
        now: Date = Date(),
        expectedSnapshot: MeetingReprocessingSnapshot? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) async throws -> MeetingReprocessingResult {
        try await database.writer.write { db in
            try cancellationCheck()
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: meetingId)
            }
            if let expectedSnapshot {
                let existing = try Utterance.filter(Column("meetingId") == meetingId).fetchAll(db)
                guard meeting.audioSHA256 == expectedSnapshot.audioSHA256,
                      existing.sorted(by: { $0.id < $1.id }) == expectedSnapshot.utterances.sorted(by: { $0.id < $1.id }) else {
                    throw MeetingReprocessingSnapshotError.changed
                }
            }
            guard meeting.durationMs >= 0, drafts.allSatisfy({
                $0.startMs >= 0 && $0.endMs >= $0.startMs && $0.endMs <= meeting.durationMs
            }) else { throw MeetingReprocessingTimingError.invalidRange }

            var draftsByIndex: [Int: ReprocessedSpeakerDraft] = [:]
            for draft in speakerDrafts {
                guard draft.speakerIndex >= 0 else {
                    throw RepositoryError.negativeDisplayIndex(
                        meetingId: meetingId, displayIndex: draft.speakerIndex
                    )
                }
                guard draftsByIndex.updateValue(draft, forKey: draft.speakerIndex) == nil else {
                    throw RepositoryError.duplicateDisplayIndex(
                        meetingId: meetingId, displayIndex: draft.speakerIndex
                    )
                }
            }
            for draft in drafts {
                if let index = draft.speakerIndex, draftsByIndex[index] == nil {
                    throw RepositoryError.notFound(
                        table: MeetingSpeaker.databaseTableName, id: String(index)
                    )
                }
            }

            try db.execute(sql: "DELETE FROM utterance WHERE meetingId = ?", arguments: [meetingId])
            try db.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId = ?", arguments: [meetingId])

            var usedNames = Set(try String.fetchAll(db, sql: "SELECT anonymousName FROM speaker"))
            var speakerIdsByIndex: [Int: String] = [:]
            for draft in speakerDrafts.sorted(by: { $0.speakerIndex < $1.speakerIndex }) {
                let speakerId: String
                if let existingId = draft.existingSpeakerId {
                    guard try Speaker.exists(db, key: existingId) else {
                        throw RepositoryError.notFound(table: Speaker.databaseTableName, id: existingId)
                    }
                    speakerId = existingId
                } else {
                    let name = AnonymousNameGenerator.nextName(usedNames: Array(usedNames))
                    usedNames.insert(name)
                    let speaker = Speaker(
                        anonymousName: name,
                        colorIndex: try Speaker.fetchCount(db) % 12,
                        createdAt: now,
                        updatedAt: now,
                        originDeviceId: deviceId
                    )
                    try speaker.insert(db)
                    speakerId = speaker.id
                }
                speakerIdsByIndex[draft.speakerIndex] = speakerId

            }

            var linkedSpeakerIds: Set<String> = []
            for draft in speakerDrafts.sorted(by: { $0.speakerIndex < $1.speakerIndex }) {
                guard let speakerId = speakerIdsByIndex[draft.speakerIndex],
                      linkedSpeakerIds.insert(speakerId).inserted else { continue }
                try MeetingSpeaker(
                    meetingId: meetingId,
                    speakerId: speakerId,
                    displayIndex: draft.speakerIndex,
                    createdAt: now,
                    updatedAt: now,
                    originDeviceId: deviceId
                ).insert(db)
            }

            for draft in drafts {
                try Utterance(
                    id: draft.id,
                    meetingId: meetingId,
                    startMs: draft.startMs,
                    endMs: draft.endMs,
                    text: draft.text,
                    speakerId: draft.speakerIndex.flatMap { speakerIdsByIndex[$0] },
                    localeIdentifier: draft.localeIdentifier,
                    confidence: draft.confidence,
                    engine: engine,
                    revision: 1,
                    createdAt: now,
                    updatedAt: now,
                    originDeviceId: deviceId
                ).insert(db)
            }

            try cancellationCheck()
            meeting.localeIdentifier = try PrimaryLanguage.derive(db, meetingId: meetingId)
            meeting.updatedAt = now
            meeting.originDeviceId = deviceId
            try meeting.update(db)

            return MeetingReprocessingResult(
                utteranceCount: drafts.count,
                speakerCount: linkedSpeakerIds.count
            )
        }
    }
}