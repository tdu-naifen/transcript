import AudioToolbox
import AVFoundation
import Darwin
import Foundation
import GRDB
import TranscriptCore

/// A local persistence boundary, not a network protocol. The adapter must authenticate both
/// pinned identities and decode the exact verified transcript bytes using its negotiated codec.
actor MacMeetingCopyInbox {
    enum Failure: Error, Equatable {
        case invalidOffer, unauthorized, conflictingOperation, meetingExists, unknownOperation
        case quotaExceeded, invalidChunk, wrongOffset, digestMismatch, incomplete
        case invalidTranscript, invalidAudio, unsafeFile, cancelled
    }

    struct Asset: Equatable, Sendable {
        let byteCount: Int
        /// Lowercase hexadecimal SHA-256; adapters convert their wire representation.
        let sha256: String
    }

    struct Manifest: Equatable, Sendable {
        let meetingID: String
        let title: String
        let startedAtMs: Int64
        let createdAtMs: Int64
        let updatedAtMs: Int64
        let durationMs: Int
        let locale: String?
        let originDeviceID: String
        let audio: Asset
        let transcript: Asset
        let revision: String
        let parentRevision: String?
        let source: String
    }

    struct Offer: Sendable {
        let peerIdentity: Data
        let receiverIdentity: Data
        let operationID: UUID
        /// Exact immutable bytes from the adapter, bound independently of decoded metadata.
        let manifestSnapshot: Data
        let manifestSHA256: String
        let manifest: Manifest
    }

    struct Segment: Sendable {
        let id: String
        let startMs: Int
        let endMs: Int
        let text: String
        let locale: String?
        let revision: Int
        let source: String
    }

    struct Transcript: Sendable {
        let revision: String
        let parentRevision: String?
        let locale: String?
        let segments: [Segment]
    }

    enum AssetKind: String, Hashable, Sendable { case audio, transcript }

    struct Prefix: Equatable, Sendable {
        let offset: Int
        let sha256: String
    }

    /// Historical proof of a completed commit, not a claim that the user has never deleted it.
    struct Receipt: Equatable, Sendable {
        let id: UUID
        let operationID: UUID
        let meetingID: String
        let manifestSHA256: String
        let committedAt: Date
    }

    struct Status: Sendable {
        let audio: Prefix
        let transcript: Prefix
        let receipt: Receipt?
    }

    static let chunkLimit = 768
    static let audioLimit = 128 * 1024 * 1024
    static let transcriptLimit = 16 * 1024 * 1024
    static let quota = 256 * 1024 * 1024
    /// Unfinished copies expire after seven days without an accepted offer or new chunk.
    /// Local discard may release them earlier; neither path deletes committed copies.
    static let pendingLifetime: TimeInterval = 7 * 24 * 60 * 60
    private let context: MacLibraryContext
    private let staging: URL
    private struct HashKey: Hashable {
        let operation: UUID
        let asset: AssetKind
    }
    private var prefixHashers: [HashKey: IncrementalSHA256] = [:]

    init(context: MacLibraryContext) throws {
        self.context = context
        staging = context.directory.appendingPathComponent("MacMeetingCopyInbox", isDirectory: true)
        try Self.checkDirectory(context.directory)
        guard mkdir(staging.path, S_IRWXU) == 0 || errno == EEXIST else { throw Self.posixError() }
        try Self.checkDirectory(staging)
        try Self.checkDirectory(context.audioFiles.directory)
        // Configure the existing writer connection, outside a transaction. Shared migrations
        // stay untouched; chunks, imported records and receipts use this same durable writer.
        try context.database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA fullfsync = ON")
            try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
            try db.inTransaction {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS mac_copy_inbox (
                        operation TEXT PRIMARY KEY NOT NULL,
                        meetingKey TEXT UNIQUE NOT NULL,
                        binding BLOB NOT NULL,
                        peer BLOB NOT NULL,
                        receiver BLOB NOT NULL,
                        reservedBytes INTEGER NOT NULL,
                        audioOffset INTEGER NOT NULL DEFAULT 0,
                        transcriptOffset INTEGER NOT NULL DEFAULT 0,
                        chunkCount INTEGER NOT NULL DEFAULT 0,
                        state TEXT NOT NULL DEFAULT 'receiving',
                        receipt TEXT,
                        committedAt DOUBLE,
                        lastActivity DOUBLE NOT NULL DEFAULT 0
                    );
                    CREATE TABLE IF NOT EXISTS mac_copy_chunks (
                        operation TEXT NOT NULL REFERENCES mac_copy_inbox(operation),
                        asset TEXT NOT NULL,
                        offset INTEGER NOT NULL,
                        bytes BLOB NOT NULL,
                        digest TEXT NOT NULL,
                        PRIMARY KEY(operation, asset, offset)
                    );
                    CREATE TABLE IF NOT EXISTS mac_copy_deleted_meetings (
                        meetingKey TEXT PRIMARY KEY NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS mac_copy_utterance_casefold ON utterance(lower(id));
                    CREATE INDEX IF NOT EXISTS mac_copy_meeting_casefold ON meeting(lower(id));
                    CREATE TRIGGER IF NOT EXISTS mac_copy_remember_meeting_deletion
                    AFTER DELETE ON meeting BEGIN
                        INSERT OR IGNORE INTO mac_copy_deleted_meetings VALUES(lower(OLD.id));
                    END;
                    """)
                if try !db.columns(in: "mac_copy_inbox").contains(where: { $0.name == "lastActivity" }) {
                    try db.execute(sql: "ALTER TABLE mac_copy_inbox ADD COLUMN lastActivity DOUBLE NOT NULL DEFAULT 0")
                    // Existing installations have no activity clock. Grant their pending
                    // copies one retention window from this local schema upgrade.
                    try db.execute(sql: "UPDATE mac_copy_inbox SET lastActivity = ?",
                                   arguments: [Date().timeIntervalSince1970])
                }
                try Self.discardPendingRows(db, context: context,
                                            olderThan: Date().timeIntervalSince1970 - Self.pendingLifetime)
                return .commit
            }
            let finished = try String.fetchAll(db, sql: "SELECT operation FROM mac_copy_inbox WHERE state != 'receiving'")
            for operation in finished {
                guard UUID(uuidString: operation)?.uuidString == operation else { throw Failure.unsafeFile }
                let stage = context.directory.appendingPathComponent("MacMeetingCopyInbox")
                    .appendingPathComponent(operation + ".m4a")
                if try Self.fileIdentity(stage) != nil {
                    guard unlink(stage.path) == 0 else { throw Self.posixError() }
                }
            }
            try Self.syncDirectory(context.directory.appendingPathComponent("MacMeetingCopyInbox"))
            try Self.syncDirectory(context.directory)
        }
    }

    func reserve(_ offer: Offer) throws -> Status {
        try validate(offer)
        try Task.checkCancellation()
        // Commit expiry separately: rejecting a just-expired offer must not roll back
        // cleanup and leave its stale reservation occupying an active slot.
        let expired = try durableWrite { db in
            try Self.discardPendingRows(db, context: context,
                                        olderThan: Date().timeIntervalSince1970 - Self.pendingLifetime)
        }
        if expired > 0 { prefixHashers.removeAll() }
        try durableWrite { db in
            if try Row.fetchOne(db, sql: "SELECT * FROM mac_copy_inbox WHERE operation = ?",
                                arguments: [offer.operationID.uuidString]) != nil {
                _ = try authorizedRow(db, offer)
                try db.execute(sql: """
                    UPDATE mac_copy_inbox SET lastActivity = ? WHERE operation = ? AND state = 'receiving'
                    """, arguments: [Date().timeIntervalSince1970, offer.operationID.uuidString])
                return
            }
            try rejectMeetingCollision(db, offer)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mac_copy_inbox") ?? 0
            let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mac_copy_inbox WHERE state = 'receiving'") ?? 0
            let reserved = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(reservedBytes), 0) FROM mac_copy_inbox WHERE state = 'receiving'
                """) ?? 0
            let size = offer.manifest.audio.byteCount + offer.manifest.transcript.byteCount
            guard count < 10_000, active < 4, size <= Self.quota - reserved else {
                throw Failure.quotaExceeded
            }
            guard try !destinationExists(offer) else { throw Failure.meetingExists }
            try db.execute(sql: """
                INSERT INTO mac_copy_inbox(operation, meetingKey, binding, peer, receiver, reservedBytes, lastActivity)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [offer.operationID.uuidString, offer.manifest.meetingID.lowercased(),
                                 binding(offer), offer.peerIdentity, offer.receiverIdentity, size, Date().timeIntervalSince1970])
        }
        return try status(offer)
    }

    func status(_ offer: Offer) throws -> Status {
        try validate(offer)
        defer { clearCachedHashes(offer.operationID) }
        return try context.database.reader.read { db in
            let row = try authorizedRow(db, offer)
            if let receipt = try receipt(row, offer) {
                return Status(
                    audio: Prefix(offset: offer.manifest.audio.byteCount, sha256: offer.manifest.audio.sha256),
                    transcript: Prefix(offset: offer.manifest.transcript.byteCount, sha256: offer.manifest.transcript.sha256),
                    receipt: receipt
                )
            }
            let audio = try verifiedPrefix(db, offer, .audio)
            let transcript = try verifiedPrefix(db, offer, .transcript)
            guard audio.offset == (row["audioOffset"] as Int),
                  transcript.offset == (row["transcriptOffset"] as Int) else { throw Failure.digestMismatch }
            return Status(audio: audio, transcript: transcript, receipt: nil)
        }
    }

    /// Returns the durable prefix without rescanning earlier chunks on every acknowledgment.
    /// `status` and `finalize` still verify persisted bytes independently of the cache.
    /// Arbitrary nonempty chunks are supported, with a total cap of 262,144 chunks per offer.
    @discardableResult
    func append(_ bytes: Data, asset: AssetKind, offset: Int, sha256: String, offer: Offer) throws -> Prefix {
        try validate(offer)
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= Self.chunkLimit, offset >= 0 else { throw Failure.invalidChunk }
        guard Self.hash(bytes) == sha256 else { throw Failure.digestMismatch }
        let descriptor = asset == .audio ? offer.manifest.audio : offer.manifest.transcript
        guard offset <= descriptor.byteCount, bytes.count <= descriptor.byteCount - offset else {
            throw Failure.invalidChunk
        }
        let key = HashKey(operation: offer.operationID, asset: asset)
        let committedHasher = try durableWrite { db in
            let row = try authorizedRow(db, offer)
            guard (row["state"] as String) == "receiving" else { throw Failure.conflictingOperation }
            let column = asset == .audio ? "audioOffset" : "transcriptOffset"
            let current: Int = row[column]
            if offset < current {
                let old = try Row.fetchOne(db, sql: """
                    SELECT bytes, digest FROM mac_copy_chunks WHERE operation = ? AND asset = ? AND offset = ?
                    """, arguments: [offer.operationID.uuidString, asset.rawValue, offset])
                guard let old, (old["bytes"] as Data) == bytes, (old["digest"] as String) == sha256 else {
                    throw Failure.wrongOffset
                }
            } else {
                guard offset == current else { throw Failure.wrongOffset }
            }
            var hasher: IncrementalSHA256
            if let cached = prefixHashers[key], cached.byteCount == current {
                hasher = cached
            } else {
                hasher = try verifiedHasher(db, offer, asset)
                guard hasher.byteCount == current else { throw Failure.digestMismatch }
            }
            if offset < current { return hasher }
            guard (row["chunkCount"] as Int) < 262_144 else { throw Failure.quotaExceeded }
            try db.execute(sql: """
                INSERT INTO mac_copy_chunks(operation, asset, offset, bytes, digest) VALUES (?, ?, ?, ?, ?)
                """, arguments: [offer.operationID.uuidString, asset.rawValue, offset, bytes, sha256])
            try db.execute(sql: """
                UPDATE mac_copy_inbox SET \(column) = ?, chunkCount = chunkCount + 1, lastActivity = ? WHERE operation = ?
                """, arguments: [current + bytes.count, Date().timeIntervalSince1970, offer.operationID.uuidString])
            hasher.update(bytes)
            return hasher
        }
        // Keep an unfinalized value copy, and publish it only after SQLite commits. A
        // failed write cannot advance the cached digest past the acknowledged prefix.
        if prefixHashers[key] == nil, prefixHashers.count >= 8 { prefixHashers.removeAll() }
        prefixHashers[key] = committedHasher
        return Self.prefix(committedHasher)
    }

    func finalize(
        _ offer: Offer,
        decodeTranscript: @Sendable (Data) throws -> Transcript
    ) throws -> Receipt {
        try validate(offer)
        try Task.checkCancellation()
        defer { clearCachedHashes(offer.operationID) }
        let result: Receipt = try durableWrite { db in
            let row = try authorizedRow(db, offer)
            if let existing = try receipt(row, offer) { return existing }
            guard (row["audioOffset"] as Int) == offer.manifest.audio.byteCount,
                  (row["transcriptOffset"] as Int) == offer.manifest.transcript.byteCount else {
                throw Failure.incomplete
            }
            try rejectMeetingCollision(db, offer, excludingOperation: true)
            var transcriptBytes = Data()
            let transcriptPrefix = try verifiedPrefix(db, offer, .transcript) { transcriptBytes.append($0) }
            guard transcriptPrefix.sha256 == offer.manifest.transcript.sha256,
                  transcriptPrefix.offset == offer.manifest.transcript.byteCount else { throw Failure.digestMismatch }
            let transcript = try decodeTranscript(transcriptBytes)
            try validateTranscript(transcript, manifest: offer.manifest)
            try Self.checkDirectory(staging)
            try Self.checkDirectory(context.audioFiles.directory)
            let stage = staging.appendingPathComponent(offer.operationID.uuidString + ".m4a")
            let destination = try context.audioFiles.url(for: offer.manifest.meetingID.lowercased())
            if try Self.fileIdentity(stage) != nil, try !destinationExists(offer) {
                // A crash may have interrupted materialization. SQLite chunks, not an
                // unlinked stage, are the durable authority; rebuild from their verified bytes.
                guard unlink(stage.path) == 0 else { throw Self.posixError() }
            }
            // A hard link is the ownership proof across crashes between file placement and
            // SQLite commit. Never infer ownership merely from a matching name or hash.
            if try Self.fileIdentity(stage) == nil {
                let fd = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw Self.posixError() }
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do {
                    let prefix = try verifiedPrefix(db, offer, .audio) { try output.write(contentsOf: $0) }
                    guard prefix.sha256 == offer.manifest.audio.sha256,
                          prefix.offset == offer.manifest.audio.byteCount else { throw Failure.digestMismatch }
                    try output.synchronize()
                    guard fcntl(fd, F_FULLFSYNC) == 0 else { throw Self.posixError() }
                    try output.close()
                    try Self.syncDirectory(staging)
                } catch {
                    // No destination can refer to a newly-created, unfinished stage.
                    guard unlink(stage.path) == 0 else { throw Self.posixError() }
                    throw error
                }
            }
            let digest = try IncrementalSHA256.hashFile(at: stage)
            guard digest.sha256 == offer.manifest.audio.sha256,
                  digest.byteCount == offer.manifest.audio.byteCount else { throw Failure.digestMismatch }
            try Self.validateAudio(stage, durationMs: offer.manifest.durationMs)
            try Task.checkCancellation()
            if try destinationExists(offer) {
                guard let stagedIdentity = try Self.fileIdentity(stage),
                      let landedIdentity = try Self.fileIdentity(destination),
                      stagedIdentity == landedIdentity else { throw Failure.meetingExists }
            } else {
                guard link(stage.path, destination.path) == 0 else { throw Self.posixError() }
            }
            try Self.syncDirectory(context.audioFiles.directory)
            let manifest = offer.manifest
            // Match the persisted Unix timestamp's precision on the first receipt as
            // well as on replay (Date internally uses a different reference epoch).
            let committedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
            let meeting = Meeting(
                id: manifest.meetingID, title: manifest.title, startedAt: Self.date(manifest.startedAtMs),
                durationMs: manifest.durationMs, localeIdentifier: manifest.locale,
                audioFileName: destination.lastPathComponent, audioSHA256: manifest.audio.sha256,
                audioByteCount: manifest.audio.byteCount, state: .recorded,
                syncedToMacAt: committedAt, audioVerifiedOnMacAt: committedAt,
                createdAt: Self.date(manifest.createdAtMs), updatedAt: Self.date(manifest.updatedAtMs),
                originDeviceId: manifest.originDeviceID
            )
            try meeting.insert(db)
            try AutomaticSyncRepository.captureSealedAudio(db, meeting: meeting)
            for segment in transcript.segments {
                try Task.checkCancellation()
                guard try !Self.recordExists(db, table: "utterance", id: segment.id) else {
                    throw Failure.invalidTranscript
                }
                let utterance = Utterance(
                    id: segment.id, meetingId: manifest.meetingID, startMs: segment.startMs,
                    endMs: segment.endMs, text: segment.text, localeIdentifier: segment.locale,
                    engine: segment.source == "appleSpeech" ? .appleSpeech : .nemotron,
                    revision: segment.revision, createdAt: Self.date(manifest.createdAtMs),
                    updatedAt: Self.date(manifest.updatedAtMs), originDeviceId: manifest.originDeviceID
                )
                try utterance.insert(db)
            }
            let receipt = Receipt(id: UUID(), operationID: offer.operationID, meetingID: manifest.meetingID,
                                  manifestSHA256: offer.manifestSHA256, committedAt: committedAt)
            try db.execute(sql: """
                UPDATE mac_copy_inbox SET state = 'committed', receipt = ?, committedAt = ?
                WHERE operation = ?
                """, arguments: [receipt.id.uuidString, committedAt.timeIntervalSince1970, offer.operationID.uuidString])
            try db.execute(sql: "DELETE FROM mac_copy_chunks WHERE operation = ?", arguments: [offer.operationID.uuidString])
            return receipt
        }
        // The SQLite transaction has committed before a receipt can escape this method.
        try removeStage(offer)
        return result
    }

    /// Keeps the operation binding permanently, so cancellation cannot be replayed as a new offer.
    /// A completed operation remains replayable and is never undone by cancellation.
    func cancel(_ offer: Offer) throws {
        try validate(offer)
        defer { clearCachedHashes(offer.operationID) }
        try durableWrite { db in
            let row = try authorizedRow(db, offer, allowCancelled: true)
            guard (row["state"] as String) == "receiving" else { return }
            try Self.checkDirectory(staging)
            try Self.checkDirectory(context.audioFiles.directory)
            let stage = staging.appendingPathComponent(offer.operationID.uuidString + ".m4a")
            let destination = try context.audioFiles.url(for: offer.manifest.meetingID.lowercased())
            if let stageID = try Self.fileIdentity(stage), let destinationID = try Self.fileIdentity(destination),
               stageID == destinationID {
                guard try !Self.recordExists(db, table: "meeting", id: offer.manifest.meetingID) else {
                    throw Failure.meetingExists
                }
                guard unlink(destination.path) == 0 else { throw Self.posixError() }
                try Self.syncDirectory(context.audioFiles.directory)
            }
            try removeStage(offer)
            try db.execute(sql: "DELETE FROM mac_copy_chunks WHERE operation = ?", arguments: [offer.operationID.uuidString])
            try db.execute(sql: "UPDATE mac_copy_inbox SET state = 'cancelled' WHERE operation = ?",
                           arguments: [offer.operationID.uuidString])
        }
    }

    /// Explicit local storage management, not a remote cancellation/delete protocol.
    /// Cancelled bindings remain permanent and committed copies/receipts are excluded.
    func discardPending() throws {
        _ = try durableWrite { db in
            try Self.discardPendingRows(db, context: context, olderThan: nil)
        }
        prefixHashers.removeAll()
    }

    @discardableResult
    private static func discardPendingRows(
        _ db: Database, context: MacLibraryContext, olderThan cutoff: TimeInterval?
    ) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT operation, meetingKey FROM mac_copy_inbox
            WHERE state = 'receiving' AND (? IS NULL OR lastActivity < ?)
            """, arguments: [cutoff, cutoff])
        guard !rows.isEmpty else { return 0 }
        let staging = context.directory.appendingPathComponent("MacMeetingCopyInbox", isDirectory: true)
        try checkDirectory(staging)
        try checkDirectory(context.audioFiles.directory)
        for row in rows {
            try Task.checkCancellation()
            let operation: String = row["operation"]
            let meeting: String = row["meetingKey"]
            guard validID(operation), UUID(uuidString: operation)?.uuidString == operation,
                  validID(meeting), UUID(uuidString: meeting)?.uuidString.lowercased() == meeting else {
                throw Failure.unsafeFile
            }
            let stage = staging.appendingPathComponent(operation + ".m4a")
            let destination = try context.audioFiles.url(for: meeting)
            if let stageID = try fileIdentity(stage) {
                if let destinationID = try fileIdentity(destination), destinationID == stageID,
                   try !recordExists(db, table: "meeting", id: meeting) {
                    guard unlink(destination.path) == 0 else { throw posixError() }
                    try syncDirectory(context.audioFiles.directory)
                }
                // Removing only this staging link cannot remove another destination's
                // bytes. A foreign destination (different inode) is never unlinked.
                guard unlink(stage.path) == 0 else { throw posixError() }
                try syncDirectory(staging)
            }
            try db.execute(sql: "DELETE FROM mac_copy_chunks WHERE operation = ?", arguments: [operation])
            try db.execute(sql: "UPDATE mac_copy_inbox SET state = 'cancelled' WHERE operation = ?",
                           arguments: [operation])
        }
        return rows.count
    }

    private func validate(_ offer: Offer) throws {
        guard offer.peerIdentity.count == 32, offer.receiverIdentity.count == 32,
              offer.peerIdentity != offer.receiverIdentity else { throw Failure.unauthorized }
        let m = offer.manifest
        guard !offer.manifestSnapshot.isEmpty, offer.manifestSnapshot.count <= 16_384,
              Self.hash(offer.manifestSnapshot) == offer.manifestSHA256,
              Self.validID(offer.operationID.uuidString),
              Self.validID(m.meetingID), Self.validID(m.revision),
              m.parentRevision == nil || (Self.validID(m.parentRevision!) && m.parentRevision?.lowercased() != m.revision.lowercased()),
              !m.title.isEmpty, m.title.utf8.count <= 512,
              !m.originDeviceID.isEmpty, m.originDeviceID.utf8.count <= 256, m.originDeviceID != context.deviceID,
              (0...253_402_300_799_999).contains(m.startedAtMs),
              (0...253_402_300_799_999).contains(m.createdAtMs),
              (m.createdAtMs...253_402_300_799_999).contains(m.updatedAtMs),
              (0...604_800_000).contains(m.durationMs),
              Self.validLocale(m.locale), m.source == "publishedLocalTranscript",
              (1...Self.audioLimit).contains(m.audio.byteCount),
              (1...Self.transcriptLimit).contains(m.transcript.byteCount),
              Self.validHash(m.audio.sha256), Self.validHash(m.transcript.sha256) else { throw Failure.invalidOffer }
    }

    private func binding(_ offer: Offer) -> Data {
        let m = offer.manifest
        // Length-prefixed local comparison key. This is deliberately not a Codable wire schema.
        var result = Data()
        for value in [m.meetingID, m.title, String(m.startedAtMs), String(m.createdAtMs), String(m.updatedAtMs),
                      String(m.durationMs), m.locale, m.originDeviceID, String(m.audio.byteCount), m.audio.sha256,
                      String(m.transcript.byteCount), m.transcript.sha256, m.revision, m.parentRevision, m.source] {
            guard let value else { result.append(contentsOf: "-1:".utf8); continue }
            result.append(contentsOf: "\(value.utf8.count):".utf8)
            result.append(contentsOf: value.utf8)
        }

        result.append(offer.manifestSnapshot)
        return result
    }

    private func durableWrite<T>(_ body: (Database) throws -> T) throws -> T {
        // synchronous/fullfsync are connection-local. A different library pool may use
        // NORMAL; enforce durability on this serialized writer for EVERY inbox commit,
        // including when another owner has reconfigured this very connection.
        try context.database.writer.writeWithoutTransaction { db in
            let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 2
            let fullfsync = try Int.fetchOne(db, sql: "PRAGMA fullfsync") ?? 0
            let checkpoint = try Int.fetchOne(db, sql: "PRAGMA checkpoint_fullfsync") ?? 0
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA fullfsync = ON")
            try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
            defer {
                // Failure to restore only leaves the stronger durability setting enabled.
                try? db.execute(sql: "PRAGMA synchronous = \(synchronous)")
                try? db.execute(sql: "PRAGMA fullfsync = \(fullfsync)")
                try? db.execute(sql: "PRAGMA checkpoint_fullfsync = \(checkpoint)")
            }
            var result: T?
            try db.inTransaction {
                try Task.checkCancellation()
                result = try body(db)
                // In particular, cancellation while decoding/importing must roll back the
                // meeting and receipt, even when the transcript has no utterances.
                try Task.checkCancellation()
                return .commit
            }
            return result!
        }
    }

    private func authorizedRow(_ db: Database, _ offer: Offer, allowCancelled: Bool = false) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mac_copy_inbox WHERE operation = ?",
                                        arguments: [offer.operationID.uuidString]) else { throw Failure.unknownOperation }
        guard (row["peer"] as Data) == offer.peerIdentity,
              (row["receiver"] as Data) == offer.receiverIdentity else { throw Failure.unauthorized }
        guard (row["binding"] as Data) == binding(offer) else { throw Failure.conflictingOperation }
        guard allowCancelled || (row["state"] as String) != "cancelled" else { throw Failure.cancelled }
        return row
    }

    private func receipt(_ row: Row, _ offer: Offer) throws -> Receipt? {
        guard (row["state"] as String) == "committed" else { return nil }
        guard let raw: String = row["receipt"], let id = UUID(uuidString: raw),
              let timestamp: Double = row["committedAt"] else { throw Failure.digestMismatch }
        return Receipt(id: id, operationID: offer.operationID, meetingID: offer.manifest.meetingID,
                       manifestSHA256: offer.manifestSHA256, committedAt: Date(timeIntervalSince1970: timestamp))
    }

    private func rejectMeetingCollision(_ db: Database, _ offer: Offer, excludingOperation: Bool = false) throws {
        let key = offer.manifest.meetingID.lowercased()
        guard try !Self.recordExists(db, table: "meeting", id: key),
              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mac_copy_deleted_meetings WHERE meetingKey = ?)",
                                arguments: [key]) != true else { throw Failure.meetingExists }
        let operation = excludingOperation ? offer.operationID.uuidString : ""
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mac_copy_inbox WHERE meetingKey = ? AND operation != ?)",
                             arguments: [key, operation]) == true { throw Failure.meetingExists }
    }

    private static func recordExists(_ db: Database, table: String, id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE lower(id) = ?)",
                          arguments: [id.lowercased()]) == true
    }

    private func verifiedPrefix(
        _ db: Database, _ offer: Offer, _ asset: AssetKind, consume: (Data) throws -> Void = { _ in }
    ) throws -> Prefix {
        Self.prefix(try verifiedHasher(db, offer, asset, consume: consume))
    }

    private func verifiedHasher(
        _ db: Database, _ offer: Offer, _ asset: AssetKind, consume: (Data) throws -> Void = { _ in }
    ) throws -> IncrementalSHA256 {
        var hasher = IncrementalSHA256()
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT offset, bytes, digest FROM mac_copy_chunks WHERE operation = ? AND asset = ? ORDER BY offset
            """, arguments: [offer.operationID.uuidString, asset.rawValue])
        while let row = try cursor.next() {
            try Task.checkCancellation()
            let data: Data = row["bytes"]
            guard (row["offset"] as Int) == hasher.byteCount, !data.isEmpty, data.count <= Self.chunkLimit,
                  Self.hash(data) == (row["digest"] as String) else { throw Failure.digestMismatch }
            hasher.update(data)
            try consume(data)
        }
        return hasher
    }

    private static func prefix(_ hasher: IncrementalSHA256) -> Prefix {
        var snapshot = hasher
        return Prefix(offset: hasher.byteCount, sha256: snapshot.finalize())
    }

    private func clearCachedHashes(_ operation: UUID) {
        prefixHashers.removeValue(forKey: HashKey(operation: operation, asset: .audio))
        prefixHashers.removeValue(forKey: HashKey(operation: operation, asset: .transcript))
    }

    private func validateTranscript(_ transcript: Transcript, manifest: Manifest) throws {
        guard transcript.revision == manifest.revision, transcript.parentRevision == manifest.parentRevision,
              transcript.locale == manifest.locale, transcript.segments.count <= 100_000 else {
            throw Failure.invalidTranscript
        }
        var ids = Set<String>()
        var previous = 0
        var textBytes = 0
        for segment in transcript.segments {
            try Task.checkCancellation()
            textBytes += segment.text.utf8.count
            guard Self.validID(segment.id), ids.insert(segment.id.lowercased()).inserted,
                  segment.startMs >= previous, segment.endMs >= segment.startMs,
                  segment.endMs <= manifest.durationMs, segment.text.utf8.count <= 65_536,
                  textBytes <= Self.transcriptLimit, Self.validLocale(segment.locale),
                  (1...Int(Int32.max)).contains(segment.revision),
                  TranscriptionEngine(rawValue: segment.source) != nil else { throw Failure.invalidTranscript }
            previous = segment.startMs
        }
    }

    private func destinationExists(_ offer: Offer) throws -> Bool {
        try Self.checkDirectory(context.audioFiles.directory)
        let name = try context.audioFiles.fileName(for: offer.manifest.meetingID.lowercased())
        return try FileManager.default.contentsOfDirectory(atPath: context.audioFiles.directory.path)
            .contains { $0.lowercased() == name }
    }

    private func removeStage(_ offer: Offer) throws {
        try Self.checkDirectory(staging)
        let stage = staging.appendingPathComponent(offer.operationID.uuidString + ".m4a")
        if try Self.fileIdentity(stage) != nil {
            guard unlink(stage.path) == 0 else { throw Self.posixError() }
            try Self.syncDirectory(staging)
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func fileIdentity(_ url: URL) throws -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeFile }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func checkDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw Failure.unsafeFile }
        var path = url.standardizedFileURL
        while path.path != "/" {
            var info = stat()
            guard lstat(path.path, &info) == 0 else { throw posixError() }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeFile }
            path.deleteLastPathComponent()
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private static func validateAudio(_ url: URL, durationMs: Int) throws {
        var handle: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &handle) == noErr, let handle else {
            throw Failure.invalidAudio
        }
        defer { AudioFileClose(handle) }
        var type: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(handle, kAudioFilePropertyFileFormat, &size, &type) == noErr,
              type == kAudioFileM4AType || type == kAudioFileMPEG4Type else { throw Failure.invalidAudio }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                throw Failure.invalidAudio
            }
            var frames: Int64 = 0
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw Failure.invalidAudio }
                frames += Int64(buffer.frameLength)
                guard Double(frames) / format.sampleRate <= 604_803 else { throw Failure.invalidAudio }
            }
            let actualMs = Double(frames) / format.sampleRate * 1000
            // Wire v2 permits zero duration (rounded/unknown at export). Still require
            // real decodable audio within the same three-second timestamp tolerance.
            guard actualMs >= 1, abs(actualMs - Double(durationMs)) <= 3_000 else { throw Failure.invalidAudio }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.invalidAudio
        }
    }

    private static func hash(_ data: Data) -> String {
        var hash = IncrementalSHA256()
        hash.update(data)
        return hash.finalize()
    }

    private static func validID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
            && value != "00000000-0000-0000-0000-000000000000"
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validLocale(_ value: String?) -> Bool {
        value == nil || (!value!.isEmpty && value!.utf8.count <= 64)
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
