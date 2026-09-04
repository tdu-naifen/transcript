import Foundation
import GRDB

public struct MeetingRepository: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    public func insert(_ meeting: Meeting) async throws {
        try await database.writer.write { db in
            try meeting.insert(db)
        }
    }

    public func fetch(id: String) async throws -> Meeting? {
        try await database.reader.read { db in
            try Meeting.fetchOne(db, key: id)
        }
    }

    /// Newest first.
    public func fetchAll() async throws -> [Meeting] {
        try await database.reader.read { db in
            try Meeting.order(Meeting.Columns.startedAt.desc).fetchAll(db)
        }
    }

    public func fetchAll(state: MeetingState) async throws -> [Meeting] {
        try await database.reader.read { db in
            try Meeting
                .filter(Meeting.Columns.state == state.rawValue)
                .order(Meeting.Columns.startedAt.desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public func rename(
        id: String,
        title: String,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Meeting {
        try await database.writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
            meeting.title = title
            meeting.updatedAt = now
            meeting.originDeviceId = deviceId
            try meeting.update(db)
            return meeting
        }
    }

    /// Records `failedFromState` when entering `failed`, and requires that leaving
    /// `failed` lands on a legal successor of it (PLAN §3.2.1).
    ///
    /// Entering `recorded` is the one moment the transcript is complete and immutable,
    /// so the derived `localeIdentifier` summary is recomputed here exactly once
    /// (PLAN §9.4) rather than left to callers.
    @discardableResult
    public func transition(
        id: String,
        to newState: MeetingState,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Meeting {
        try await database.writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
            try Self.applyTransition(db, to: &meeting, newState: newState, deviceId: deviceId, now: now)
            try meeting.update(db)
            return meeting
        }
    }

    /// Seals Layer A and moves the state machine in a single transaction.
    ///
    /// PLAN §9.4.1: nothing used to write `durationMs`, so a stopped or crashed recording
    /// landed in `recorded` with a zero duration and no hash. Sealing is therefore not
    /// exposed as four separate setters — a meeting either has all of Layer A or it is
    /// still `recording`.
    ///
    /// `audio` is optional only for the salvage path, where a crash may have left a
    /// duration but no readable file; the duration is preserved either way, because
    /// losing a meeting is unacceptable (PLAN §3.2.1).
    @discardableResult
    public func sealRecording(
        id: String,
        to newState: MeetingState = .recorded,
        durationMs: Int,
        audio: SealedAudio?,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Meeting {
        try await database.writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
            meeting.durationMs = max(0, durationMs)
            if let audio {
                meeting.audioFileName = audio.fileName
                meeting.audioSHA256 = audio.sha256
                meeting.audioByteCount = audio.byteCount
            }
            try Self.applyTransition(db, to: &meeting, newState: newState, deviceId: deviceId, now: now)
            try meeting.update(db)
            return meeting
        }
    }

    private static func applyTransition(
        _ db: Database,
        to meeting: inout Meeting,
        newState: MeetingState,
        deviceId: String,
        now: Date
    ) throws {
        guard meeting.state.canTransition(to: newState, failedFrom: meeting.failedFromState) else {
            throw IllegalMeetingStateTransition(
                from: meeting.state, to: newState, failedFrom: meeting.failedFromState
            )
        }
        meeting.failedFromState = Meeting.normalizedFailedFromState(
            state: newState,
            failedFromState: newState == .failed ? meeting.state : nil
        )
        meeting.state = newState
        if newState == .recorded {
            meeting.localeIdentifier = try PrimaryLanguage.derive(db, meetingId: meeting.id)
        }
        meeting.updatedAt = now
        meeting.originDeviceId = deviceId
    }

    /// Bytes finished transferring. Written by the iPhone (PLAN §3.4).
    public func markAudioSynced(id: String, deviceId: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE meeting
                    SET syncedToMacAt = ?, updatedAt = ?, originDeviceId = ?
                    WHERE id = ?
                    """,
                arguments: [now, now, deviceId, id]
            )
            guard db.changesCount == 1 else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
        }
    }

    /// The Mac re-hashed the landed file and SHA-256 matched, then told the iPhone.
    ///
    /// PLAN §3.1 permits this one cross-device write **because** it is write-once and
    /// monotonic, so that is enforced rather than assumed: the timestamp is only ever
    /// assigned while the column is NULL. A later call is a no-op and returns the
    /// timestamp already in effect, so an out-of-order message cannot roll it back.
    @discardableResult
    public func markAudioVerifiedOnMac(
        id: String,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Date {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE meeting
                    SET audioVerifiedOnMacAt = ?, updatedAt = ?, originDeviceId = ?
                    WHERE id = ? AND audioVerifiedOnMacAt IS NULL
                    """,
                arguments: [now, now, deviceId, id]
            )
            if db.changesCount == 1 { return now }
            guard let existing = try Date.fetchOne(
                db, sql: "SELECT audioVerifiedOnMacAt FROM meeting WHERE id = ?", arguments: [id]
            ) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
            return existing
        }
    }

    /// PLAN §3.4: the gate is Mac-side verification, not "bytes transferred".
    /// This is the only irreversible data-loss path in the product, so the same rule is
    /// also a CHECK constraint on the table; this error just explains it better.
    public func markLocalAudioPurged(id: String, deviceId: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            guard let meeting = try Meeting.fetchOne(db, key: id) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
            guard meeting.audioVerifiedOnMacAt != nil else {
                throw RepositoryError.audioNotVerifiedOnMac(meetingId: id)
            }
            try db.execute(
                sql: """
                    UPDATE meeting
                    SET localAudioPurgedAt = ?, updatedAt = ?, originDeviceId = ?
                    WHERE id = ?
                    """,
                arguments: [now, now, deviceId, id]
            )
        }
    }

    /// Recomputes the denormalized `localeIdentifier` summary from the utterances
    /// that actually carry the language truth (PLAN §9.2). ``transition(id:to:deviceId:now:)``
    /// already does this on `recording → recorded`; this is for backfill/repair.
    @discardableResult
    public func refreshPrimaryLanguage(
        id: String,
        deviceId: String,
        now: Date = Date()
    ) async throws -> String? {
        try await database.writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
            meeting.localeIdentifier = try PrimaryLanguage.derive(db, meetingId: id)
            meeting.updatedAt = now
            meeting.originDeviceId = deviceId
            try meeting.update(db)
            return meeting.localeIdentifier
        }
    }

    /// The derived primary language without writing it back.
    public func primaryLanguage(id: String) async throws -> String? {
        try await database.reader.read { db in
            try PrimaryLanguage.derive(db, meetingId: id)
        }
    }

    public func delete(id: String) async throws {
        try await database.writer.write { db in
            guard try Meeting.deleteOne(db, key: id) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: id)
            }
        }
    }
}
