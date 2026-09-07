import Foundation
import GRDB
import CryptoKit

/// Local-only immutable export queue. This is not a replication or deletion policy.
public struct MeetingCopyOutbox: Sendable {
    public enum Failure: Error, Sendable {
        case unavailable, staleSnapshot, duplicate, cancelled, invalid, capacity, sourceProcessing
        case transcriptTiming, transcriptInvalid, transcriptProvenance, audioMismatch
        case transcriptIdentity, legacyConsentRequired
    }
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

    public static func sourceFingerprint(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(snapshot)))
    }

    public static func legacyIdentifierCount(in snapshot: Snapshot) throws -> Int {
        try snapshot.utterances.reduce(0) { count, item in
            if case .legacy = try identifier(item, meetingID: snapshot.meeting.id) { return count + 1 }
            return count
        }
    }

    /// An export representation only. The raw snapshot remains the source of truth.
    public static func copyIdentifiers(in snapshot: Snapshot, allowingLegacy: Bool = false) throws -> [String] {
        let classified = try snapshot.utterances.map { try identifier($0, meetingID: snapshot.meeting.id) }
        if !allowingLegacy, classified.contains(where: { if case .legacy = $0 { true } else { false } }) {
            throw Failure.legacyConsentRequired
        }
        let ids = classified.map { identifier in
            switch identifier {
            case .canonical(let id): return id
            case .legacy(let seed):
                var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
                bytes[6] = (bytes[6] & 0x0f) | 0x80
                bytes[8] = (bytes[8] & 0x3f) | 0x80
                return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                    .uuidString.lowercased()
            }
        }
        guard Set(ids).count == ids.count else { throw Failure.transcriptIdentity }
        return ids
    }

    private enum CopyIdentifier { case canonical(String), legacy(String) }

    private static func canonicalUUID(_ value: String) -> String? {
        guard value.count == 36, let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value.lowercased(),
              value != "00000000-0000-0000-0000-000000000000" else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func identifier(_ item: Utterance, meetingID: String) throws -> CopyIdentifier {
        if let uuid = canonicalUUID(item.id) { return .canonical(uuid) }
        let prefix = "\(meetingID)-apple-"
        guard item.engine == .appleSpeech, item.startMs >= 0,
              let meeting = canonicalUUID(meetingID), item.id.hasPrefix(prefix) else {
            throw Failure.transcriptIdentity
        }
        let remainder = item.id.dropFirst(prefix.count)
        let rawStream = String(remainder.prefix(36))
        guard let stream = canonicalUUID(rawStream),
              item.id == "\(prefix)\(rawStream)-\(item.startMs)" else { throw Failure.transcriptIdentity }
        // Fixed recipe: UUID fields and the canonical integer cannot contain the delimiter.
        return .legacy("transcript.copy.legacy-apple-id.v1|\(meeting)|\(stream)|\(item.startMs)")
    }

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
              meeting.localAudioPurgedAt == nil else { throw Failure.unavailable }
        try assertSettled(db, id: id)
        guard let hash = meeting.audioSHA256, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let count = meeting.audioByteCount, count > 0,
              count <= 8 * 1024 * 1024 * 1024 else { throw Failure.audioMismatch }
        // Do not allocate an arbitrarily large published transcript before checking the bound.
        let countRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterance WHERE meetingId = ?", arguments: [id]) ?? 0
        let size = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(text AS BLOB))), 0) FROM utterance WHERE meetingId = ?", arguments: [id]) ?? 0
        guard countRows <= 100_000, size <= 16 * 1024 * 1024 else { throw Failure.transcriptInvalid }
        // Older published rows may extend past the sealed recording. Reject without
        // clamping their times or changing the original meeting to make an export fit.
        let invalidTiming = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM utterance
                WHERE meetingId = ? AND (startMs < 0 OR endMs < startMs OR endMs > ?))
            """, arguments: [id, meeting.durationMs]) ?? false
        guard !invalidTiming else { throw Failure.transcriptTiming }
        let invalidProvenance = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM utterance
                WHERE meetingId = ? AND (engine NOT IN ('appleSpeech', 'nemotron') OR revision < 1 OR revision > 2147483647))
            """, arguments: [id]) ?? false
        guard !invalidProvenance else { throw Failure.transcriptProvenance }
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
