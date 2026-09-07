import CryptoKit
import Darwin
import Foundation
import GRDB

/// Bounded, restartable immutable-byte transfer. It owns only files under its
/// caller-provided application directory; peer values never become paths.
public struct AutomaticSyncResourceTransfer: Sendable {
    public typealias Wire = AutomaticSyncResourceWire

    private let database: AppDatabase
    private let directory: URL
    private let quotaBytes: Int64

    public init(_ database: AppDatabase, directory: URL, quotaBytes: Int64 = 512 * 1_024 * 1_024) {
        self.database = database
        self.directory = directory.standardizedFileURL
        self.quotaBytes = max(0, quotaBytes)
    }

    public func chunk(resourceID: String, offset: Int64, for peerID: String,
                      audioDirectory: URL? = nil) async throws -> AutomaticSyncResourceWire.Chunk? {
        guard offset >= 0 else { throw AutomaticSyncWire.Failure.invalid }
        let repository = AutomaticSyncRepository(database)
        let audio = if let audioDirectory {
            try await repository.localAudioResourceURL(id: resourceID, for: peerID, audioDirectory: audioDirectory)
        } else { nil as URL? }
        return try await database.reader.read { db in
            let descriptor = try Self.authorize(db, id: resourceID, peerID: peerID)
            guard offset <= descriptor.byteCount else { throw AutomaticSyncWire.Failure.invalid }
            if offset == descriptor.byteCount { return nil }
            let count = Int(min(768, descriptor.byteCount - offset))
            let bytes: Data
            if let payload = try Data.fetchOne(db, sql: """
                SELECT substr(bytes,?,?) FROM automaticSyncResourcePayload WHERE resourceID=?
                """, arguments: [offset + 1, count, resourceID]) {
                bytes = payload
            } else {
                let stored = try String.fetchOne(db, sql: "SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND verified=1", arguments: [resourceID])
                guard let url = stored.map({ URL(fileURLWithPath: $0) }) ?? audio else { throw AutomaticSyncWire.Failure.resourceUnavailable }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                bytes = try handle.read(upToCount: count) ?? Data()
            }
            guard bytes.count == count else { throw AutomaticSyncWire.Failure.resourceUnavailable }
            return .init(resourceID: resourceID, offset: offset, total: descriptor.byteCount, bytes: bytes)
        }
    }

    public func progress(resourceID: String, from peerID: String) async throws -> Int64 {
        try await database.reader.read { db in
            let descriptor = try Self.authorize(db, id: resourceID, peerID: peerID)
            if let file = try String.fetchOne(db, sql: "SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND verified=1", arguments: [resourceID]),
               FileManager.default.fileExists(atPath: file) {
                return descriptor.byteCount
            }
            return try Int64.fetchOne(db, sql: "SELECT offset FROM automaticSyncResourceReceive WHERE peerID=? AND resourceID=?", arguments: [peerID, resourceID]) ?? 0
        }
    }

    /// Returned offset is safe to acknowledge. Bytes cross synchronize() before
    /// the FULL SQLite commit. A crash-written tail is truncated on the next retry.
    public func receive(_ chunk: AutomaticSyncResourceWire.Chunk, from peerID: String) async throws -> Int64 {
        _ = try AutomaticSyncResourceWire.decode(AutomaticSyncWire.encode(AutomaticSyncResourceWire.Message(kind: .chunk, chunk: chunk)))
        let committed = try await database.writer.write { db in
            let descriptor = try Self.authorize(db, id: chunk.resourceID, peerID: peerID)
            guard descriptor.byteCount == chunk.total, descriptor.byteCount <= quotaBytes else { throw AutomaticSyncWire.Failure.resourceUnavailable }
            if let path = try String.fetchOne(db, sql: "SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND verified=1", arguments: [chunk.resourceID]),
               FileManager.default.fileExists(atPath: path) {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? file.close() }
                try file.seek(toOffset: UInt64(chunk.offset))
                guard try file.read(upToCount: chunk.bytes.count) == chunk.bytes else { throw AutomaticSyncWire.Failure.equivocation }
                return descriptor.byteCount
            }
            try db.execute(sql: "DELETE FROM automaticSyncResourceFile WHERE resourceID=?", arguments: [chunk.resourceID])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previous = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncResourceReceive WHERE peerID=? AND resourceID=?",
                                            arguments: [peerID, chunk.resourceID])
            let offset: Int64 = previous?["offset"] ?? 0
            let name = IncrementalSHA256.hex(SHA256.hash(data: Data("\(peerID)|\(chunk.resourceID)".utf8)))
            let staging = directory.appendingPathComponent(".partial-\(name)")
            if previous == nil {
                guard chunk.offset == 0 else { throw AutomaticSyncWire.Failure.invalid }
                let reserved = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(total),0) FROM automaticSyncResourceReceive") ?? 0
                let installed = try Int64.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(size),0) FROM (
                      SELECT MAX(json_extract(o.value,'$.byteCount')) AS size
                      FROM automaticSyncResourceFile f
                      JOIN automaticSyncRegister r ON r.entity='resource' AND r.entityID=f.resourceID
                      JOIN automaticSyncOperation o ON o.id=r.operationID GROUP BY f.localPath)
                    """) ?? 0
                guard installed <= quotaBytes, reserved <= (quotaBytes - installed) / 2,
                      chunk.total <= (quotaBytes - installed) / 2 - reserved else {
                    throw AutomaticSyncWire.Failure.resourceUnavailable
                }
                guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw AutomaticSyncWire.Failure.resourceUnavailable }
                try Self.synchronizeDirectory(directory)
            } else {
                guard previous?["localPath"] as String? == staging.path else { throw AutomaticSyncWire.Failure.invalid }
            }
            let handle = try FileHandle(forUpdating: staging)
            defer { try? handle.close() }
            let actualLength = try handle.seekToEnd()
            guard actualLength >= UInt64(offset) else { throw AutomaticSyncWire.Failure.resourceUnavailable }
            try handle.truncate(atOffset: UInt64(offset))
            guard chunk.offset <= offset else { throw AutomaticSyncWire.Failure.invalid }
            let next: Int64
            if chunk.offset < offset {
                guard Int64(chunk.bytes.count) <= offset - chunk.offset else { throw AutomaticSyncWire.Failure.invalid }
                try handle.seek(toOffset: UInt64(chunk.offset))
                guard try handle.read(upToCount: chunk.bytes.count) == chunk.bytes else { throw AutomaticSyncWire.Failure.equivocation }
                next = offset
            } else {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: chunk.bytes)
                next = offset + Int64(chunk.bytes.count)
            }
            try handle.synchronize()
            if next == descriptor.byteCount {
                let digest = try IncrementalSHA256.hashFile(at: staging, chunkBytes: 65_536)
                guard digest.sha256 == descriptor.sha256, Int64(digest.byteCount) == descriptor.byteCount else {
                    throw AutomaticSyncWire.Failure.hashMismatch
                }
                let target = directory.appendingPathComponent(descriptor.sha256 + (descriptor.kind == .audio ? ".m4a" : ""))
                try Self.publishVerified(staging, to: target, descriptor: descriptor)
                try db.execute(sql: """
                    INSERT INTO automaticSyncResourceFile VALUES(?,?,1,?)
                    ON CONFLICT(resourceID) DO UPDATE SET fileName=excluded.fileName,verified=1,localPath=excluded.localPath
                    """, arguments: [chunk.resourceID, target.lastPathComponent, target.path])
                try db.execute(sql: "DELETE FROM automaticSyncResourceReceive WHERE peerID=? AND resourceID=?", arguments: [peerID, chunk.resourceID])
                try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncFileGarbage VALUES(?)", arguments: [staging.path])
                if descriptor.kind == .audio {
                    try Self.recordAudioImport(db, resourceID: chunk.resourceID, peerID: peerID)
                }
            } else {
                try db.execute(sql: """
                    INSERT INTO automaticSyncResourceReceive(peerID,resourceID,offset,localPath,total) VALUES(?,?,?,?,?)
                    ON CONFLICT(peerID,resourceID) DO UPDATE SET offset=excluded.offset
                    """, arguments: [peerID, chunk.resourceID, next, staging.path, chunk.total])
            }

            return next
        }
        try await AutomaticSyncRepository(database).collectRevokedFiles()
        return committed
    }

    static func recordAudioImport(_ db: Database, resourceID: String, peerID: String) throws {
        try db.execute(sql: """
            INSERT INTO automaticSyncAudioImport(resourceID,peerID,operationID)
            SELECT ?,?,r.operationID FROM automaticSyncRegister r
            WHERE r.entity='resource' AND r.field='descriptor' AND r.entityID=?
            AND EXISTS(SELECT 1 FROM automaticSyncResourceSource s WHERE s.resourceID=r.entityID AND s.peerID=?)
            ON CONFLICT(resourceID) DO UPDATE SET peerID=excluded.peerID,operationID=excluded.operationID
            """, arguments: [resourceID, peerID, resourceID, peerID])
    }

    static func publishVerified(_ source: URL, to target: URL, descriptor: AutomaticSyncWire.Resource) throws {
        if let digest = try? IncrementalSHA256.hashFile(at: target, chunkBytes: 65_536),
           digest.sha256 == descriptor.sha256, Int64(digest.byteCount) == descriptor.byteCount { return }
        // Retain the journaled source until commit; only fsynced complete bytes
        // become visible at the final path, including recovery of old damage.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".publish-" + target.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: staging) }
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(staging.path, target.path) == 0 else { throw AutomaticSyncWire.Failure.resourceUnavailable }
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    /// Explicit recovery from a damaged partial file. Never touches a verified
    /// resource, the source recording, an operation, or a tombstone.
    public func discardPartial(resourceID: String, from peerID: String) async throws {
        try await database.writer.write { db in
            _ = try AutomaticSyncRepository.requirePeer(db, peerID: peerID)
            try db.execute(sql: """
                INSERT OR IGNORE INTO automaticSyncFileGarbage
                SELECT localPath FROM automaticSyncResourceReceive WHERE peerID=? AND resourceID=?
                """, arguments: [peerID, resourceID])
            try db.execute(sql: "DELETE FROM automaticSyncResourceReceive WHERE peerID=? AND resourceID=?", arguments: [peerID, resourceID])
        }
        try await AutomaticSyncRepository(database).collectRevokedFiles()
    }

    private static func authorize(_ db: Database, id: String, peerID: String) throws -> AutomaticSyncWire.Resource {
        let consent = try AutomaticSyncRepository.requirePeer(db, peerID: peerID)
        guard let descriptor = try AutomaticSyncRepository.resource(db, id: id) else { throw AutomaticSyncWire.Failure.resourceUnavailable }
        guard descriptor.kind != .voiceprint || consent == .allowed else { throw AutomaticSyncWire.Failure.consentRequired }
        return descriptor
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw AutomaticSyncWire.Failure.resourceUnavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw AutomaticSyncWire.Failure.resourceUnavailable }
    }
}
