import Foundation
import GRDB
import Synchronization

/// Cancellation and the persisted chunk-boundary decision have one linearization
/// point. Once committed, that already accepted chunk must use the new locale.
public final class RecordingLanguageBoundary: Sendable {
    private enum State { case pending, cancelled, committed }
    private let state = Mutex(State.pending)
    public init() {}
    public func cancel() {
        state.withLock { if $0 == .pending { $0 = .cancelled } }
    }
    fileprivate func commit(_ operation: () throws -> Void) throws {
        try state.withLock {
            guard $0 != .cancelled else { throw CancellationError() }
            try operation()
            $0 = .committed
        }
    }
}

/// Device-local intent only: never exported, synchronized, or added to the outbox.
public struct RecordingProcessingJob: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "recordingProcessingJob"
    public enum State: String, Codable, Sendable {
        case capturing, processing, needsRetry, interrupted, complete
    }
    public var meetingId: String
    public var state: State
    public var localeIdentifier: String?
    public var requiresSegmentedRetry: Bool = false
    public var audioSHA256: String?
    public var error: String?
    public var updatedAt: Date
}

public struct RecordingProcessingRepository: Sendable {
    private let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func insertRecording(_ meeting: Meeting, localeIdentifier: String?) async throws {
        try await database.writer.write { db in
            try meeting.insert(db)
            try RecordingProcessingJob(
                meetingId: meeting.id, state: .capturing, localeIdentifier: localeIdentifier,
                updatedAt: Date()
            ).insert(db)
        }
    }

    public func begin(meetingId: String, localeIdentifier: String?) async throws {
        try await database.writer.write { db in
            try RecordingProcessingJob(
                meetingId: meetingId, state: .capturing, localeIdentifier: localeIdentifier,
                updatedAt: Date()
            ).insert(db)
        }
    }

    public func fetch(meetingId: String) async throws -> RecordingProcessingJob? {
        try await database.reader.read { try RecordingProcessingJob.fetchOne($0, key: meetingId) }
    }

    public func fetchAll() async throws -> [RecordingProcessingJob] {
        try await database.reader.read { try RecordingProcessingJob.fetchAll($0) }
    }

    public func markLanguageChange(meetingId: String) async throws {
        try await database.writer.write {
            try $0.execute(
                sql: "UPDATE recordingProcessingJob SET requiresSegmentedRetry = 1 WHERE meetingId = ?",
                arguments: [meetingId]
            )
        }

    }

    public func commitLanguageBoundary(
        meetingId: String, previousLocale: String?, newLocale: String,
        boundary: RecordingLanguageBoundary
    ) async throws {
        try await database.writer.write { db in
            try boundary.commit {
                try db.execute(sql: """
                    INSERT INTO recordingProcessingJob
                        (meetingId, state, localeIdentifier, requiresSegmentedRetry, updatedAt)
                    SELECT id, 'capturing', ?, 0, ? FROM meeting WHERE id = ?
                    ON CONFLICT(meetingId) DO NOTHING
                    """, arguments: [previousLocale ?? newLocale, Date(), meetingId])
                try db.execute(sql: """
                    UPDATE recordingProcessingJob SET
                        localeIdentifier = CASE WHEN ? IS NULL THEN ? ELSE localeIdentifier END,
                        requiresSegmentedRetry = requiresSegmentedRetry OR ?
                    WHERE meetingId = ?
                    """, arguments: [
                        previousLocale, newLocale,
                        previousLocale.map { Locale(identifier: $0) != Locale(identifier: newLocale) } ?? false,
                        meetingId
                    ])
                guard db.changesCount == 1 else {
                    throw RepositoryError.notFound(table: Meeting.databaseTableName, id: meetingId)
                }
            }
        }
    }

    /// Update, never upsert: a late worker must not resurrect a deleted meeting/job.
    public func recordFailure(meetingId: String, error: String) async throws {
        try await database.writer.write {
            try $0.execute(sql: """
                UPDATE recordingProcessingJob SET error = ?, updatedAt = ?,
                    state = CASE WHEN state = 'capturing' THEN state ELSE 'needsRetry' END
                WHERE meetingId = ?
                """, arguments: [error, Date(), meetingId])
        }
    }

    public func update(meetingId: String, state: RecordingProcessingJob.State, error: String? = nil) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE recordingProcessingJob SET state = ?, error = ?, updatedAt = ?,
                    audioSHA256 = (SELECT audioSHA256 FROM meeting WHERE id = ?)
                WHERE meetingId = ?
                """, arguments: [state.rawValue, error, Date(), meetingId, meetingId])
        }
    }

    /// Explicit retry only; existing text, edits, language spans and audio stay untouched.
    public func interruptUnfinished(excluding liveIDs: Set<String> = []) async throws {
        try await database.writer.write { db in
            for var job in try RecordingProcessingJob.fetchAll(db)
                where !liveIDs.contains(job.meetingId) && [.capturing, .processing].contains(job.state) {
                job.state = .interrupted
                job.updatedAt = Date()
                try job.update(db)
            }
        }
    }
}
