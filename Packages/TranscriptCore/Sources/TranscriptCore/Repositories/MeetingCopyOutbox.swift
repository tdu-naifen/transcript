import Foundation
import GRDB

/// Local-only immutable export queue. This is not a replication or deletion policy.
public struct MeetingCopyOutbox: Sendable {
    public enum Failure: Error, Sendable { case unavailable, staleSnapshot, duplicate, cancelled, invalid, capacity, sourceProcessing }
    public static let maximumEntries = 200
    public static let maximumStoredBytes = 64 * 1024 * 1024
    public struct Snapshot: Codable, Equatable, Sendable {
        public let meeting: Meeting
        public let utterances: [Utterance]
    }

    public struct Entry: Codable, FetchableRecord, PersistableRecord, Sendable {
        public static let databaseTableName = "meetingCopyOutbox"
        public let id: String
        public let meetingId: String
        public let peerKey: Data
        public let manifest: Data
        public let transcript: Data
        public let snapshot: Data
        public let sourceIdentity: Data
        public var state: String
        public var error: String?
        public var receipt: Data?
        public let createdAt: Date
    }

    public struct Summary: Decodable, FetchableRecord, Sendable {
        public let id: String
        public let meetingId: String
        public let manifest: Data
        public let state: String
        public let error: String?
    }

    private let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    // GRDB's WAL pool normally uses synchronous=NORMAL. Delivery intent and receipts
    // must cross a FULL commit before the sender exposes them as saved.
    private func durableWrite<T: Sendable>(
        _ updates: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await database.writer.writeWithoutTransaction { db in
            try Task.checkCancellation()
            let previous = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 1
            try db.execute(sql: "PRAGMA synchronous = FULL")
            defer { try? db.execute(sql: "PRAGMA synchronous = \(previous)") }
            var result: T?
            try db.inTransaction {
                result = try updates(db)
                try Task.checkCancellation()
                return .commit
            }
            return result!
        }
    }

    private static func snapshot(_ db: Database, id: String) throws -> Snapshot {
        guard let meeting = try Meeting.fetchOne(db, key: id),
              meeting.state != .recording, meeting.audioFileName != nil,
              meeting.audioSHA256?.count == 64, let count = meeting.audioByteCount,
              count > 0, count <= 8 * 1024 * 1024 * 1024,
              meeting.localAudioPurgedAt == nil else { throw Failure.unavailable }
        try assertSettled(db, id: id)
        // Do not allocate an arbitrarily large published transcript before checking the bound.
        let countRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterance WHERE meetingId = ?", arguments: [id]) ?? 0
        let size = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(text AS BLOB))), 0) FROM utterance WHERE meetingId = ?", arguments: [id]) ?? 0
        guard countRows <= 100_000, size <= 16 * 1024 * 1024 else { throw Failure.invalid }
        let utterances = try Utterance
            .filter(Utterance.Columns.meetingId == id)
            .order(Utterance.Columns.startMs, Column("id")).fetchAll(db)
        return Snapshot(meeting: meeting, utterances: utterances)
    }

    private static func assertSettled(_ db: Database, id: String) throws {
        let active = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM recordingProcessingJob
                WHERE meetingId = ? AND state IN ('capturing', 'processing'))
                OR EXISTS(SELECT 1 FROM speakerAnalysisJob
                WHERE meetingId = ? AND state IN ('pending', 'running', 'rerun'))
            """, arguments: [id, id]) ?? false
        guard !active else { throw Failure.sourceProcessing }
    }

    public func snapshot(meetingID: String) async throws -> Snapshot {
        try await database.reader.read { db in try Self.snapshot(db, id: meetingID) }
    }

    /// The caller hashes the sealed file outside SQLite, then this transaction revalidates
    /// the exact source rows and atomically owns all exported JSON bytes.
    public func enqueue(snapshot: Snapshot, peerKey: Data, manifest: Data, transcript: Data, sourceIdentity: Data,
                        operationID: String = UUID().uuidString.lowercased()) async throws -> Entry {
        guard peerKey.count == 32, !manifest.isEmpty, manifest.count <= 1600,
              !transcript.isEmpty, transcript.count <= 16 * 1024 * 1024,
              !sourceIdentity.isEmpty, sourceIdentity.count <= 1024,
              UUID(uuidString: operationID)?.uuidString.lowercased() == operationID else { throw Failure.invalid }
        let bytes = try JSONEncoder().encode(snapshot)
        return try await durableWrite { db in
            guard try Self.snapshot(db, id: snapshot.meeting.id) == snapshot else { throw Failure.staleSnapshot }
            guard try Entry.filter(Column("meetingId") == snapshot.meeting.id && Column("peerKey") == peerKey)
                .fetchOne(db) == nil else { throw Failure.duplicate }
            let storedBytes = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(length(manifest) + length(transcript) + length(snapshot) + length(sourceIdentity)), 0)
                FROM meetingCopyOutbox
                """) ?? 0
            let addedBytes = manifest.count + transcript.count + bytes.count + sourceIdentity.count
            guard try Entry.fetchCount(db) < Self.maximumEntries,
                  addedBytes <= Self.maximumStoredBytes,
                  storedBytes <= Self.maximumStoredBytes - addedBytes else { throw Failure.capacity }
            let entry = Entry(id: operationID, meetingId: snapshot.meeting.id, peerKey: peerKey,
                              manifest: manifest, transcript: transcript, snapshot: bytes, sourceIdentity: sourceIdentity,
                              state: "queued", createdAt: Date())
            try entry.insert(db)
            return entry
        }
    }

    public func entries() async throws -> [Entry] {
        try await database.reader.read { db in try Entry.order(Column("createdAt")).fetchAll(db) }
    }

    public func summaries() async throws -> [Summary] {
        try await database.reader.read { db in
            try Summary.fetchAll(db, sql: """
                SELECT id, meetingId, manifest, state, error FROM meetingCopyOutbox
                ORDER BY CASE WHEN state IN ('queued', 'cancelled', 'stale') THEN 0 ELSE 1 END, createdAt DESC LIMIT 200
                """)
        }
    }

    public func entry(id: String) async throws -> Entry {
        try await database.reader.read { db in
            guard let value = try Entry.fetchOne(db, key: id) else { throw Failure.unavailable }
            return value
        }
    }

    public func validate(id: String) async throws -> Snapshot {
        try await database.reader.read { db in
            guard let entry = try Entry.fetchOne(db, key: id),
                  entry.state == "queued" else { throw Failure.cancelled }
            let frozen = try JSONDecoder().decode(Snapshot.self, from: entry.snapshot)
            guard try Self.snapshot(db, id: entry.meetingId) == frozen else { throw Failure.staleSnapshot }
            return frozen
        }
    }

    public func assertPending(id: String) async throws {
        try await database.reader.read { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM meetingCopyOutbox WHERE id = ?", arguments: [id]) == "queued" else {
                throw Failure.staleSnapshot
            }
            if let meetingID = try String.fetchOne(db, sql: "SELECT meetingId FROM meetingCopyOutbox WHERE id = ?", arguments: [id]) {
                try Self.assertSettled(db, id: meetingID)
            }
        }
    }

    public func noteFailure(id: String, message: String) async throws {
        try await durableWrite { db in
            try db.execute(sql: "UPDATE meetingCopyOutbox SET error = ? WHERE id = ? AND state = 'queued'",
                           arguments: [String(message.prefix(500)), id])
        }
    }

    /// Cancellation is local and persisted; it never claims remote rollback.
    public func cancel(id: String) async throws {
        try await durableWrite { db in
            try db.execute(sql: "UPDATE meetingCopyOutbox SET state = 'cancelled', error = NULL WHERE id = ? AND state = 'queued'", arguments: [id])
        }
    }

    public func retry(id: String) async throws {
        try await durableWrite { db in
            try db.execute(sql: "UPDATE meetingCopyOutbox SET state = 'queued', error = NULL WHERE id = ? AND state IN ('queued', 'cancelled')", arguments: [id])
        }
    }

    /// Only the authenticated sender calls this after validating a bound durable receipt.
    /// It does not authorize purging audio, overwrite local content, or advance processing state.
    public func recordReceipt(id: String, manifest: Data, receipt: Data) async throws {
        guard !receipt.isEmpty, receipt.count <= 4096 else { throw Failure.invalid }
        try await durableWrite { db in
            guard var entry = try Entry.fetchOne(db, key: id), entry.state == "queued",
                  entry.manifest == manifest, entry.receipt == nil else { throw Failure.invalid }
            let frozen = try JSONDecoder().decode(Snapshot.self, from: entry.snapshot)
            guard try Self.snapshot(db, id: entry.meetingId) == frozen else { throw Failure.staleSnapshot }
            entry.state = "done"
            entry.error = nil
            entry.receipt = receipt
            try entry.update(db)
            try db.execute(sql: "UPDATE meeting SET syncedToMacAt = ? WHERE id = ?", arguments: [Date(), entry.meetingId])
        }
    }
}
