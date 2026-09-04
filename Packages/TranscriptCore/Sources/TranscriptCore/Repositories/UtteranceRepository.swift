import Foundation
import GRDB

public struct UtteranceRepository: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// Layer B is append-only (PLAN §3.1).
    public func append(_ utterances: [Utterance]) async throws {
        try await database.writer.write { db in
            for utterance in utterances {
                try utterance.insert(db)
            }
        }
    }

    public func append(_ utterance: Utterance) async throws {
        try await append([utterance])
    }

    public func fetch(meetingId: String) async throws -> [Utterance] {
        try await database.reader.read { db in
            try Utterance
                .filter(Utterance.Columns.meetingId == meetingId)
                .order(Utterance.Columns.startMs)
                .fetchAll(db)
        }
    }

    public func count(meetingId: String) async throws -> Int {
        try await database.reader.read { db in
            try Utterance.filter(Utterance.Columns.meetingId == meetingId).fetchCount(db)
        }
    }

    /// Speaker assignment is iPhone-owned (Layer C). Bumps `revision`.
    public func assignSpeaker(
        utteranceId: String,
        speakerId: String?,
        deviceId: String,
        now: Date = Date()
    ) async throws {
        try await database.writer.write { db in
            guard var utterance = try Utterance.fetchOne(db, key: utteranceId) else {
                throw RepositoryError.notFound(table: Utterance.databaseTableName, id: utteranceId)
            }
            utterance.speakerId = speakerId
            utterance.revision += 1
            utterance.updatedAt = now
            utterance.originDeviceId = deviceId
            try utterance.update(db)
        }
    }

    /// Batch form of ``assignSpeaker(utteranceId:speakerId:deviceId:now:)``, used when
    /// live diarization revises several segments at once. An id that does not belong to
    /// `meetingId` aborts the whole batch rather than silently succeeding.
    public func reassignSpeakers(
        meetingId: String,
        assignments: [String: String],
        deviceId: String,
        now: Date = Date()
    ) async throws {
        try await database.writer.write { db in
            for (utteranceId, speakerId) in assignments {
                try db.execute(
                    sql: """
                        UPDATE utterance
                        SET speakerId = ?, revision = revision + 1,
                            updatedAt = ?, originDeviceId = ?
                        WHERE id = ? AND meetingId = ?
                        """,
                    arguments: [speakerId, now, deviceId, utteranceId, meetingId]
                )
                guard db.changesCount == 1 else {
                    throw RepositoryError.notFound(
                        table: Utterance.databaseTableName, id: utteranceId
                    )
                }
            }
        }
    }

    /// Total spoken duration per language tag for a meeting (PLAN §9.2).
    public func localeDurations(meetingId: String) async throws -> [String: Int] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localeIdentifier, SUM(MAX(endMs - startMs, 0)) AS durationMs
                FROM utterance
                WHERE meetingId = ? AND localeIdentifier IS NOT NULL
                GROUP BY localeIdentifier
                """, arguments: [meetingId])
            return Dictionary(
                uniqueKeysWithValues: rows.map { ($0["localeIdentifier"] as String, $0["durationMs"] as Int) }
            )
        }
    }
}
