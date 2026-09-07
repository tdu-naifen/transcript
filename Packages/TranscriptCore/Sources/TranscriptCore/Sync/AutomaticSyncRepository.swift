import CryptoKit
import Foundation
import GRDB

public struct AutomaticSyncRepository: Sendable {
    public typealias Wire = AutomaticSyncWire
    let database: AppDatabase

    public struct Status: Sendable, Equatable {
        public var enabled: Bool
        public var voiceprints: Wire.Consent
        public var pendingCount: Int
        public var conflictCount: Int
    }

    public init(_ database: AppDatabase) { self.database = database }

    /// Coalesced post-commit invalidations, including an initial startup value.
    /// Re-query projections/imports; this is not an operation receipt stream.
    public func changes() -> AsyncValueObservation<Void> {
        ValueObservation.tracking { db in
            for table in [
                "meeting", "speaker", "utterance", "meetingSpeaker", "speakerEmbedding",
                "analysisResult", "automaticSyncOperation", "automaticSyncPeer",
                "automaticSyncResourceFile", "automaticSyncAudioImport", "automaticSyncPublication",
                "automaticSyncResourceSource", "automaticSyncDeletedMeetingAudio"
            ] {
                // Register every column without loading audio, vectors or transcript rows.
                _ = try Row.fetchOne(db, sql: "SELECT * FROM \(table) LIMIT 0")
            }
        }.values(in: database.reader, bufferingPolicy: .bufferingNewest(1))
    }

    public func deviceID() async throws -> String {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT deviceID FROM automaticSyncState WHERE id=1")!
        }
    }

    public func configure(peerID: String, enabled: Bool, voiceprints: Wire.Consent = .denied) async throws {
        guard Self.validID(peerID) else { throw Wire.Failure.invalid }
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO automaticSyncPeer(id,enabled,consent) VALUES(?,?,?)
                ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled
                """, arguments: [peerID, enabled, voiceprints.rawValue])
            if enabled { try Self.captureUnregisteredVoiceprints(db) }
            if voiceprints == .revoked { try Self.revoke(db, peerID: peerID) }
        }
        if voiceprints == .revoked { try await collectRevokedFiles() }
    }

    public func setVoiceprintConsent(peerID: String, state: Wire.Consent) async throws {
        try await database.writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM automaticSyncPeer WHERE id=?", arguments: [peerID]) != nil else {
                throw Wire.Failure.disabled
            }
            try db.execute(sql: "UPDATE automaticSyncPeer SET consent=? WHERE id=?", arguments: [state.rawValue, peerID])
            if state == .allowed { try Self.captureUnregisteredVoiceprints(db) }
            if state != .allowed {
                try db.execute(sql: "DELETE FROM automaticSyncFragment WHERE peerID=?", arguments: [peerID])
            }
            if state == .revoked { try Self.revoke(db, peerID: peerID) }
        }
        if state == .revoked { try await collectRevokedFiles() }
    }

    public func status(peerID: String) async throws -> Status {
        try await database.reader.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncPeer WHERE id=?", arguments: [peerID])
            let consent = Wire.Consent(rawValue: row?["consent"] ?? "") ?? .denied
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM automaticSyncOperation o
                WHERE (sourcePeer IS NULL OR (sourcePeer != ? AND sourcePeer NOT GLOB 'publication:*'))
                AND (biometric=0 OR ?) AND NOT EXISTS(
                SELECT 1 FROM automaticSyncAcknowledgement a WHERE a.peerID=? AND a.operationID=o.id)
                """, arguments: [peerID, consent == .allowed, peerID]) ?? 0
            let conflicts = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM automaticSyncOperation o
                WHERE isDelete=0 AND NOT EXISTS(SELECT 1 FROM automaticSyncRegister r WHERE r.operationID=o.id)
                """) ?? 0
            return Status(enabled: row?["enabled"] ?? false, voiceprints: consent,
                          pendingCount: count, conflictCount: conflicts)
        }
    }

    public func pending(peerID: String, limit: Int = 64, includeBiometrics: Bool = true) async throws -> [Wire.Operation] {
        try await database.reader.read { db in
            let consent = try Self.requirePeer(db, peerID: peerID)
            return try Row.fetchAll(db, sql: """
                SELECT * FROM automaticSyncOperation o
                WHERE (sourcePeer IS NULL OR (sourcePeer != ? AND sourcePeer NOT GLOB 'publication:*'))
                AND (biometric=0 OR ?) AND NOT EXISTS(
                SELECT 1 FROM automaticSyncAcknowledgement a WHERE a.peerID=? AND a.operationID=o.id)
                ORDER BY counter,id LIMIT ?
                """, arguments: [peerID, consent == .allowed && includeBiometrics, peerID, max(1, min(limit, 256))]).map(Self.operation)
        }
    }

    /// Call only for exact operation IDs acknowledged in the authenticated session.
    public func acknowledge(peerID: String, operationIDs: [String]) async throws {
        guard operationIDs.count <= 256 else { throw Wire.Failure.invalid }
        try await database.writer.write { db in
            let consent = try Self.requirePeer(db, peerID: peerID)
            for id in operationIDs {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM automaticSyncOperation WHERE id=?
                    AND (sourcePeer IS NULL OR (sourcePeer != ? AND sourcePeer NOT GLOB 'publication:*'))
                    """, arguments: [id, peerID]),
                      !(row["biometric"] as Bool) || consent == .allowed else { throw Wire.Failure.invalid }
                try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncAcknowledgement VALUES(?,?)", arguments: [peerID, id])
            }
        }
    }

    /// Durable bounded contiguous reassembly. nil means more bytes are required;
    /// a returned ID may be acknowledged because application has committed.
    public func receive(_ fragment: Wire.Fragment, from peerID: String, includeBiometrics: Bool = true) async throws -> String? {
        let message = Wire.Message(kind: .fragment, fragment: fragment)
        _ = try Wire.decode(Wire.encode(message))
        return try await database.writer.write { db in
            _ = try Self.requirePeer(db, peerID: peerID)
            let existing = try Row.fetchOne(db, sql: """
                SELECT total,bytes FROM automaticSyncFragment WHERE peerID=? AND operationID=?
                """, arguments: [peerID, fragment.operationID])
            var bytes: Data = existing?["bytes"] ?? Data()
            if let existing, existing["total"] as Int != fragment.total { throw Wire.Failure.equivocation }
            guard fragment.offset <= bytes.count else { throw Wire.Failure.invalid }
            if fragment.offset < bytes.count {
                guard fragment.bytes.count <= bytes.count - fragment.offset,
                      bytes.subdata(in: fragment.offset..<(fragment.offset + fragment.bytes.count)) == fragment.bytes else {
                    throw Wire.Failure.equivocation
                }
            } else {
                bytes.append(fragment.bytes)
            }
            if bytes.count == fragment.total {
                let operation = try JSONDecoder().decode(Wire.Operation.self, from: bytes)
                guard operation.id == fragment.operationID, try Wire.encode(operation) == bytes else { throw Wire.Failure.invalid }
                guard !operation.biometric || includeBiometrics else { throw Wire.Failure.consentRequired }
                try Self.apply(db, operations: [operation], peerID: peerID)
                try db.execute(sql: "DELETE FROM automaticSyncFragment WHERE peerID=? AND operationID=?", arguments: [peerID, fragment.operationID])
                return operation.id
            }
            // Bound incomplete operations per peer; the transport sends one at a time.
            if existing == nil {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM automaticSyncFragment WHERE peerID=?", arguments: [peerID]) ?? 0
                guard count < 8 else { throw Wire.Failure.invalid }
            }
            try db.execute(sql: """
                INSERT INTO automaticSyncFragment VALUES(?,?,?,?)
                ON CONFLICT(peerID,operationID) DO UPDATE SET bytes=excluded.bytes
                """, arguments: [peerID, fragment.operationID, fragment.total, bytes])
            return nil
        }
    }

    /// The caller supplies the authenticated pinned peer, never a payload peer ID.
    @discardableResult
    public func apply(_ operations: [Wire.Operation], from peerID: String) async throws -> [String] {
        guard operations.count <= 256 else { throw Wire.Failure.invalid }
        return try await database.writer.write { db in
            try Self.apply(db, operations: operations, peerID: peerID)
            return operations.map(\.id)
        }
    }

    public func audit(entity: Wire.Entity, id: String) async throws -> [Wire.Operation] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM automaticSyncOperation WHERE entity=? AND \(AutomaticSyncSchema.canonicalSQL("entityID"))=? ORDER BY counter,deviceID,id
                """, arguments: [entity.rawValue, Self.canonicalID(id)]).map(Self.operation)
        }
    }

    public func receivedFrom(operationID: String) async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT sourcePeer FROM automaticSyncOperation WHERE id=?", arguments: [operationID])
        }
    }

    public func resourceSources(id: String) async throws -> [String] {
        try await database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT peerID FROM automaticSyncResourceSource WHERE resourceID=? ORDER BY peerID", arguments: [id])
        }
    }

    public func isDeleted(entity: Wire.Entity, id: String) async throws -> Bool {
        try await database.reader.read { try Self.deleted($0, entity: entity, id: id) }
    }

    public func values(entity: Wire.Entity, id: String) async throws -> [String: String] {
        try await database.reader.read { db in
            if try Self.deleted(db, entity: entity, id: id) { return [:] }
            return try Self.values(db, entity: entity, id: id)
        }
    }

    static func operation(_ row: Row) -> Wire.Operation {
        Wire.Operation(stamp: .init(counter: row["counter"], deviceID: row["deviceID"], operationID: row["id"]),
                       entity: Wire.Entity(rawValue: row["entity"])!, entityID: row["entityID"],
                       field: row["field"], value: row["value"], isDelete: row["isDelete"], biometric: row["biometric"])
    }

    static func recordLocal(_ db: Database, entity: Wire.Entity, id: String, field: String,
                            value: String?, delete: Bool = false, biometric: Bool = false) throws {
        guard let state = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncState WHERE id=1"),
              (state["counter"] as Int64) < Int64.max - 1 else { throw Wire.Failure.clockExhausted }
        let baseline = (state["applying"] as Int) == 2
        let counter: Int64 = baseline ? 1 : (state["counter"] as Int64) + 1
        let deviceID: String = state["deviceID"]
        let baselineIdentity: [String?] = ["baseline-v1", deviceID, entity.rawValue, canonicalID(id), field, value]
        let operationID = baseline
            ? "baseline-" + IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(baselineIdentity)))
            : UUID().uuidString.lowercased()
        let operation = Wire.Operation(stamp: .init(counter: counter, deviceID: deviceID, operationID: operationID),
                                       entity: entity, entityID: id, field: field, value: value,
                                       isDelete: delete, biometric: biometric || isBiometric(entity: entity, field: field))
        try validate(operation)
        try db.execute(sql: "UPDATE automaticSyncState SET counter=? WHERE id=1", arguments: [counter])
        try store(db, operation: operation, sourcePeer: nil)
    }

    private static func apply(_ db: Database, operations: [Wire.Operation], peerID: String) throws {
        let consent = try requirePeer(db, peerID: peerID)
        for operation in operations {
            try validate(operation)
            guard !operation.biometric || consent == .allowed else { throw Wire.Failure.consentRequired }
        }
        try db.execute(sql: "UPDATE automaticSyncState SET applying=1 WHERE id=1")
        var affected: [Wire.Entity: Set<String>] = [:]
        for operation in operations {
            if try store(db, operation: operation, sourcePeer: peerID) {
                affected[operation.entity, default: []].insert(canonicalID(operation.entityID))
            }
            // Receiving these exact bytes proves this authenticated peer already
            // knows the operation, including a duplicate relayed by another peer.
            try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncAcknowledgement VALUES(?,?)",
                           arguments: [peerID, operation.id])
            try db.execute(sql: "UPDATE automaticSyncState SET counter=MAX(counter,?) WHERE id=1", arguments: [operation.stamp.counter])
        }
        if !affected.isEmpty { try materialize(db, affected: affected) }
        try db.execute(sql: "UPDATE automaticSyncState SET applying=0 WHERE id=1")
    }

    @discardableResult
    static func store(_ db: Database, operation op: Wire.Operation, sourcePeer: String?) throws -> Bool {
        if op.entity == .resource, !op.isDelete, let sourcePeer {
            try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncResourceSource VALUES(?,?)", arguments: [op.entityID, sourcePeer])
            try db.execute(sql: "DELETE FROM automaticSyncRevokedResource WHERE resourceID=?", arguments: [op.entityID])
        }
        if let existing = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncOperation WHERE id=?", arguments: [op.id]) {
            guard try Wire.encode(operation(existing)) == Wire.encode(op) else { throw Wire.Failure.equivocation }
            return false
        }
        if op.entity == .resource, !op.isDelete,
           let existing = try Row.fetchOne(db, sql: """
            SELECT o.* FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
            WHERE r.entity='resource' AND r.entityID=? AND r.field='descriptor'
            """, arguments: [canonicalID(op.entityID)]), operation(existing).value != op.value {
            throw Wire.Failure.immutableResource
        }
        if op.entity == .association, !op.isDelete,
           let existing = try values(db, entity: .association, id: op.entityID)[op.field],
           canonicalID(existing) != op.value.map(canonicalID) {
            throw Wire.Failure.equivocation
        }
        try db.execute(sql: """
            INSERT INTO automaticSyncOperation(id,deviceID,counter,entity,entityID,field,value,isDelete,biometric,sourcePeer)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, arguments: [op.id, op.stamp.deviceID, op.stamp.counter, op.entity.rawValue,
                             op.entityID, op.field, databaseText(op.value), op.isDelete, op.biometric, sourcePeer])
        if op.isDelete {
            try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncTombstone VALUES(?,?)", arguments: [op.entity.rawValue, canonicalID(op.entityID)])
        } else {
            let old = try Row.fetchOne(db, sql: """
                SELECT o.* FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                WHERE r.entity=? AND r.entityID=? AND r.field=?
                """, arguments: [op.entity.rawValue, canonicalID(op.entityID), op.field])
            // Artifact-derived registers are defaults, not edits. A real target
            // correction must win whether it arrives before or after the bytes.
            // Inferred identity operations travel separately under consent, but
            // retain that same lower priority than an explicit assignment/clear.
            let incomingDefault = op.entity == .utterance
                && (sourcePeer?.hasPrefix("publication:") == true || op.id.hasPrefix("inferred-"))
            let existingDefault = old.map {
                op.entity == .utterance && (($0["sourcePeer"] as String?)?.hasPrefix("publication:") == true
                    || ($0["id"] as String).hasPrefix("inferred-"))
            } ?? false
            let replaces = old == nil || (existingDefault && !incomingDefault)
                || (existingDefault == incomingDefault && operation(old!).stamp < op.stamp)
            if replaces {
                try db.execute(sql: """
                    INSERT INTO automaticSyncRegister VALUES(?,?,?,?)
                    ON CONFLICT(entity,entityID,field) DO UPDATE SET operationID=excluded.operationID
                    """, arguments: [op.entity.rawValue, canonicalID(op.entityID), op.field, op.id])
                return true
            }
            return false
        }
        return true
    }

    static func deleted(_ db: Database, entity: Wire.Entity, id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM automaticSyncTombstone WHERE entity=? AND entityID=?)",
                          arguments: [entity.rawValue, canonicalID(id)]) ?? false
    }

    static func values(_ db: Database, entity: Wire.Entity, id: String) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT o.field,o.value FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
            WHERE r.entity=? AND r.entityID=?
            """, arguments: [entity.rawValue, canonicalID(id)])
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let value: String = row["value"] else { return nil }
            return (row["field"] as String, value)
        })
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.contains("\0")
    }

    static func canonicalID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    static func databaseText(_ value: String?) -> DatabaseValue {
        guard let value else { return .null }
        return value.contains("\0") ? Data(value.utf8).databaseValue : value.databaseValue
    }

    static func localID(_ db: Database, entity: Wire.Entity, id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { return id }
        return try String.fetchOne(db, sql: """
            SELECT id FROM \(entity.rawValue) WHERE id=? COLLATE NOCASE
            ORDER BY id LIMIT 1
            """, arguments: [id]) ?? id
    }

    static func isBiometric(entity: Wire.Entity, field: String) -> Bool {
        entity == .speaker || entity == .association || (entity == .utterance && field == "speakerId")
    }

    static func validate(_ op: Wire.Operation) throws {
        guard Wire.validStampID(op.id), Wire.validStampID(op.stamp.deviceID), validID(op.entityID),
              op.stamp.counter > 0, op.stamp.counter < Int64.max - 1,
              op.value?.utf8.count ?? 0 <= 524_288 else { throw Wire.Failure.invalid }
        if op.isDelete {
            guard op.field.isEmpty, op.value == nil else { throw Wire.Failure.invalid }
            // Resource deletions cannot hide their biometric nature.
            guard op.entity != .resource || op.biometric else { throw Wire.Failure.invalid }
            guard op.biometric == (op.entity == .resource || isBiometric(entity: op.entity, field: op.field)) else { throw Wire.Failure.invalid }
            return
        }
        guard AutomaticSyncSchema.fields[op.entity]?.contains(op.field) == true else { throw Wire.Failure.invalid }
        if op.entity == .resource {
            guard let value = op.value, let data = value.data(using: .utf8) else { throw Wire.Failure.invalid }
            let resource = try JSONDecoder().decode(Wire.Resource.self, from: data)
            try validateResource(resource)
            guard op.biometric == (resource.kind == .voiceprint), try Wire.encode(resource) == data,
                  try resourceID(resource) == op.entityID else { throw Wire.Failure.invalid }
        } else {
            guard op.biometric == isBiometric(entity: op.entity, field: op.field) else { throw Wire.Failure.invalid }
            let nullable = ["emoji", "localeIdentifier", "displayName", "speakerId", "confidence"]
            guard op.value != nil || nullable.contains(op.field) else { throw Wire.Failure.invalid }
            if let value = op.value {
                if ["meetingId", "speakerId"].contains(op.field), !validID(value) { throw Wire.Failure.invalid }
                if ["durationMs", "startMs", "endMs", "revision", "colorIndex"].contains(op.field) {
                    guard let number = Int64(value), number >= 0, number <= 2_147_483_647,
                          op.field != "revision" || number > 0 else { throw Wire.Failure.invalid }
                }
                if op.field == "confidence" {
                    guard let number = Double(value), number.isFinite, (0...1).contains(number) else { throw Wire.Failure.invalid }
                }
                if op.field == "engine", !["appleSpeech", "nemotron"].contains(value) { throw Wire.Failure.invalid }
                if ["createdAt", "startedAt"].contains(op.field) {
                    guard Date.fromDatabaseValue(value.databaseValue) != nil else { throw Wire.Failure.invalid }
                }
            }
        }
    }

    static func requirePeer(_ db: Database, peerID: String) throws -> Wire.Consent {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncPeer WHERE id=?", arguments: [peerID]),
              row["enabled"] as Bool else { throw Wire.Failure.disabled }
        return Wire.Consent(rawValue: row["consent"]) ?? .denied
    }

    private static func revoke(_ db: Database, peerID: String) throws {
        try db.execute(sql: "UPDATE automaticSyncPeer SET consent='revoked' WHERE id=?", arguments: [peerID])
        try db.execute(sql: "UPDATE automaticSyncState SET applying=1 WHERE id=1")
        // The audit retains descriptors/hashes, never vector bytes. Only this
        // peer's contribution is revoked; independent local/peer copies survive.
        let ids = try String.fetchAll(db, sql: """
            SELECT DISTINCT s.resourceID FROM automaticSyncResourceSource s
            JOIN automaticSyncOperation o ON o.entity='resource' AND o.entityID=s.resourceID
            WHERE s.peerID=? AND o.biometric=1
            """, arguments: [peerID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO automaticSyncFileGarbage
            SELECT localPath FROM automaticSyncResourceReceive s WHERE peerID=?
            AND EXISTS(SELECT 1 FROM automaticSyncOperation o WHERE o.entityID=s.resourceID AND o.entity='resource' AND o.biometric=1);
            DELETE FROM automaticSyncResourceReceive WHERE peerID=?
            AND EXISTS(SELECT 1 FROM automaticSyncOperation o WHERE o.entityID=automaticSyncResourceReceive.resourceID AND o.entity='resource' AND o.biometric=1);
            """, arguments: [peerID, peerID])
        try db.execute(sql: """
            DELETE FROM automaticSyncResourceSource WHERE peerID=?
            AND EXISTS(SELECT 1 FROM automaticSyncOperation o
                       WHERE o.entityID=automaticSyncResourceSource.resourceID
                       AND o.entity='resource' AND o.biometric=1)
            """, arguments: [peerID])
        for id in ids {
            let independent = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM automaticSyncResourceSource WHERE resourceID=?)
                OR EXISTS(SELECT 1 FROM automaticSyncResourcePayload WHERE resourceID=?)
                """, arguments: [id, id]) ?? false
            if independent { continue }
            try db.execute(sql: """
                DELETE FROM speakerEmbedding WHERE id IN(
                  SELECT embeddingID FROM automaticSyncVoiceprintProvenance WHERE resourceID=?)
                """, arguments: [id])
            try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncRevokedResource VALUES(?)", arguments: [id])
            try db.execute(sql: """
                INSERT OR IGNORE INTO automaticSyncFileGarbage
                SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND localPath IS NOT NULL
                AND NOT EXISTS(SELECT 1 FROM automaticSyncResourceFile f WHERE f.resourceID<>? AND f.localPath=automaticSyncResourceFile.localPath)
                """, arguments: [id, id])
            try db.execute(sql: "DELETE FROM automaticSyncResourceFile WHERE resourceID=?", arguments: [id])
            try db.execute(sql: "DELETE FROM automaticSyncResourcePayload WHERE resourceID=?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM automaticSyncFragment WHERE peerID=?", arguments: [peerID])
        try db.execute(sql: "UPDATE automaticSyncState SET applying=0 WHERE id=1")
    }

    /// Safe to retry after restart: consent and unavailability commit before disk
    /// cleanup, and failed filesystem removal leaves a durable cleanup intention.
    public func collectRevokedFiles() async throws {
        let paths = try await database.reader.read { try String.fetchAll($0, sql: "SELECT localPath FROM automaticSyncFileGarbage") }
        for path in paths {
            try await database.writer.write { db in
                let retained = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM automaticSyncResourceFile WHERE localPath=?)
                    OR EXISTS(SELECT 1 FROM automaticSyncResourceReceive WHERE localPath=?)
                    OR EXISTS(SELECT 1 FROM meeting WHERE audioFileName=? COLLATE NOCASE)
                    """, arguments: [path, path, URL(fileURLWithPath: path).lastPathComponent]) ?? false
                guard !retained else { return }
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                try db.execute(sql: "DELETE FROM automaticSyncFileGarbage WHERE localPath=?", arguments: [path])
            }
        }
    }
}
