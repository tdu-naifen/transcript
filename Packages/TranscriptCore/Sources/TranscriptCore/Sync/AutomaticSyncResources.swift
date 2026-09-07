import CryptoKit
import Foundation
import GRDB

extension AutomaticSyncRepository {
    public struct AudioImport: Sendable, Equatable {
        public let resourceID: String
        public let meetingID: String
        public let audioSHA256: String
        public let byteCount: Int64
        public let fileURL: URL
        public let peerID: String
        public let operationID: String
    }

    /// Durable replay source for an idempotent processing queue in another store.
    /// Scan after adoption and at startup; deduplicate by meeting, processing
    /// configuration and audioSHA256. No transient callback is required for recovery.
    public func verifiedAudioImports() async throws -> [AudioImport] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT f.resourceID,f.localPath,i.peerID,i.operationID,m.id AS meetingID FROM automaticSyncResourceFile f
                JOIN automaticSyncAudioImport i ON i.resourceID=f.resourceID
                JOIN automaticSyncPeer p ON p.id=i.peerID AND p.enabled=1
                JOIN automaticSyncRegister r ON r.entity='resource' AND r.entityID=f.resourceID AND r.field='descriptor'
                JOIN automaticSyncOperation o ON o.id=r.operationID
                JOIN meeting m ON \(AutomaticSyncSchema.canonicalSQL("m.id"))=\(AutomaticSyncSchema.canonicalSQL("json_extract(o.value,'$.meetingID')"))
                WHERE f.verified=1 AND json_extract(o.value,'$.kind')='audio'
                AND m.audioFileName=f.fileName AND m.audioSHA256=json_extract(o.value,'$.sha256')
                AND m.audioByteCount=json_extract(o.value,'$.byteCount') AND m.localAudioPurgedAt IS NULL
                AND EXISTS(SELECT 1 FROM automaticSyncResourceSource s WHERE s.resourceID=f.resourceID AND s.peerID=i.peerID)
                ORDER BY f.resourceID
                """)
            return try rows.compactMap { row in
                let id: String = row["resourceID"]
                guard let descriptor = try Self.resource(db, id: id),
                      let path: String = row["localPath"],
                      let digest = try? IncrementalSHA256.hashFile(at: URL(fileURLWithPath: path), chunkBytes: 65_536),
                      digest.sha256 == descriptor.sha256, Int64(digest.byteCount) == descriptor.byteCount else { return nil }
                return AudioImport(resourceID: id, meetingID: row["meetingID"], audioSHA256: descriptor.sha256,
                                   byteCount: descriptor.byteCount, fileURL: URL(fileURLWithPath: path),
                                   peerID: row["peerID"], operationID: row["operationID"])
            }
        }
    }

    /// Capture outbound resource intent inside the transaction that persists the meeting.
    /// This does not authorize transfer or register an automatic processing import.
    public static func captureSealedAudio(_ db: Database, meeting: Meeting) throws {
        guard meeting.state != .recording, let hash = meeting.audioSHA256,
              let count = meeting.audioByteCount, count > 0,
              hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { return }
        try registerResource(db, descriptor: .init(kind: .audio, meetingID: meeting.id,
                                                   sha256: hash, byteCount: Int64(count)))
    }

    static func captureAnalysis(_ db: Database, draft: AnalysisResultDraft, inputRevision: String,
                                modelFingerprint: String, preprocessing: String) throws {
        let bytes = try Wire.encode(draft)
        guard bytes.count <= 16 * 1_024 * 1_024 else { throw Wire.Failure.invalid }
        let descriptor = Wire.Resource(kind: .analysis, meetingID: draft.meetingId,
                                       sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)),
                                       byteCount: Int64(bytes.count), modelFingerprint: modelFingerprint,
                                       preprocessing: preprocessing, inputRevision: inputRevision)
        let id = try registerResource(db, descriptor: descriptor)
        try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncResourcePayload VALUES(?,?)", arguments: [id, bytes])
        try db.execute(sql: "INSERT INTO automaticSyncAnalysisProvenance VALUES(?,?,?)", arguments: [draft.id, id, inputRevision])
    }

    /// A caller supplying preprocessing must know the actual identity.
    /// Unknown provenance can instead be exported unchanged, in quarantine.
    @discardableResult
    public func registerVoiceprint(embeddingID: String, preprocessing: String) async throws -> String {
        try await database.writer.write { db in
            guard var embedding = try SpeakerEmbedding.fetchOne(db, key: embeddingID),
                  embedding.preprocessing == nil || embedding.preprocessing == preprocessing else { throw Wire.Failure.invalid }
            embedding.preprocessing = preprocessing
            return try Self.captureVoiceprint(db, embedding: embedding)
        }
    }

    @discardableResult
    static func captureVoiceprint(_ db: Database, embedding: SpeakerEmbedding) throws -> String {
        guard FloatVector.isValidStorage(embedding.vector, dimension: embedding.dimension),
              FloatVector.normalized(embedding.floats) != nil else { throw Wire.Failure.invalid }
        let descriptor = Wire.Resource(kind: .voiceprint, speakerID: embedding.speakerId,
            sha256: IncrementalSHA256.hex(SHA256.hash(data: embedding.vector)),
            byteCount: Int64(embedding.vector.count), modelFingerprint: embedding.modelIdentifier,
            preprocessing: embedding.preprocessing, dimensions: embedding.dimension,
            sampleCount: embedding.sampleCount)
        let id = try registerResource(db, descriptor: descriptor)
        try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncResourcePayload VALUES(?,?)", arguments: [id, embedding.vector])
        try db.execute(sql: """
            INSERT INTO automaticSyncVoiceprintProvenance VALUES(?,?)
            ON CONFLICT(embeddingID) DO UPDATE SET resourceID=excluded.resourceID
            """, arguments: [embedding.id, id])
        return id
    }

    /// Backfill existing local artifacts without re-exporting adopted resources or
    /// inventing provenance. Invalid legacy storage remains local.
    static func captureUnregisteredVoiceprints(_ db: Database) throws {
        let embeddings = try SpeakerEmbedding.fetchAll(db, sql: """
            SELECT e.* FROM speakerEmbedding e WHERE NOT EXISTS(
                SELECT 1 FROM automaticSyncVoiceprintProvenance p WHERE p.embeddingID=e.id)
            """)
        for embedding in embeddings {
            guard (1...65_536).contains(embedding.dimension), embedding.sampleCount >= 0,
                  embedding.modelIdentifier.map(validID) ?? true,
                  embedding.preprocessing.map(validID) ?? true,
                  FloatVector.isValidStorage(embedding.vector, dimension: embedding.dimension),
                  FloatVector.normalized(embedding.floats) != nil else { continue }
            try captureVoiceprint(db, embedding: embedding)
        }
    }

    /// Materializes only validated Float32 artifacts under their exact namespace.
    /// The matcher independently enforces model, preprocessing and dimensions.
    public func adoptVoiceprintResource(id: String) async throws {
        try await database.writer.write { db in
            guard let descriptor = try Self.resource(db, id: id), descriptor.kind == .voiceprint,
                  let rawSpeaker = descriptor.speakerID else { throw Wire.Failure.resourceUnavailable }
            try Self.requireResourceConsent(db, id: id, descriptor: descriptor)
            let speaker = try Self.localID(db, entity: .speaker, id: rawSpeaker)
            guard try Speaker.fetchOne(db, key: speaker) != nil else { throw Wire.Failure.resourceUnavailable }
            let bytes: Data
            if let local = try Data.fetchOne(db, sql: "SELECT bytes FROM automaticSyncResourcePayload WHERE resourceID=?", arguments: [id]) {
                bytes = local
            } else if let path = try String.fetchOne(db, sql: "SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND verified=1", arguments: [id]) {
                bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            } else { throw Wire.Failure.resourceUnavailable }
            guard bytes.count == descriptor.byteCount,
                  IncrementalSHA256.hex(SHA256.hash(data: bytes)) == descriptor.sha256,
                  let dimension = descriptor.dimensions,
                  FloatVector.isValidStorage(bytes, dimension: dimension),
                  FloatVector.normalized(FloatVector.floats(from: bytes)) != nil else { throw Wire.Failure.hashMismatch }
            let embeddingID = "sync-\(id)"
            if try SpeakerEmbedding.fetchOne(db, key: embeddingID) != nil { return }
            guard let origin = try String.fetchOne(db, sql: """
                SELECT o.deviceID FROM automaticSyncRegister r
                JOIN automaticSyncOperation o ON o.id=r.operationID
                WHERE r.entity='resource' AND r.entityID=? AND r.field='descriptor'
                """, arguments: [id]) else { throw Wire.Failure.resourceUnavailable }
            try SpeakerEmbedding(id: embeddingID, speakerId: speaker, vector: bytes, dimension: dimension,
                sampleCount: descriptor.sampleCount ?? 0,
                originDeviceId: origin, modelIdentifier: descriptor.modelFingerprint,
                preprocessing: descriptor.preprocessing).insert(db)
            try db.execute(sql: "INSERT INTO automaticSyncVoiceprintProvenance VALUES(?,?)", arguments: [embeddingID, id])
        }
    }

    /// Payload access is gated again at send time, so queued work cannot bypass a
    /// pause or revoke that occurred after the descriptor was selected.
    public func resourceBytes(id: String, for peerID: String) async throws -> Data? {
        try await database.reader.read { db in
            let consent = try Self.requirePeer(db, peerID: peerID)
            guard let descriptor = try Self.resource(db, id: id) else { throw Wire.Failure.resourceUnavailable }
            guard descriptor.kind != .voiceprint || consent == .allowed else { throw Wire.Failure.consentRequired }
            return try Data.fetchOne(db, sql: "SELECT bytes FROM automaticSyncResourcePayload WHERE resourceID=?", arguments: [id])
        }
    }

    /// Resolve a locally sealed audio file under the caller's actual audio root.
    /// No peer-supplied path is read. The transport still verifies the descriptor
    /// hash while streaming and must never send bytes after peer authorization ends.
    public func localAudioResourceURL(id: String, for peerID: String, audioDirectory: URL) async throws -> URL? {
        try await database.reader.read { db in
            _ = try Self.requirePeer(db, peerID: peerID)
            guard let descriptor = try Self.resource(db, id: id), descriptor.kind == .audio,
                  let meetingID = descriptor.meetingID,
                  let meeting = try Meeting.fetchOne(db, key: Self.localID(db, entity: .meeting, id: meetingID)),
                  meeting.audioSHA256 == descriptor.sha256,
                  meeting.audioByteCount.map(Int64.init) == descriptor.byteCount,
                  meeting.localAudioPurgedAt == nil,
                  let name = meeting.audioFileName, !name.contains("/"), !name.contains("\\"),
                  name != ".", name != ".." else { return nil }
            let root = audioDirectory.resolvingSymlinksInPath().standardizedFileURL
            let path = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard path.deletingLastPathComponent().path == root.path else { throw Wire.Failure.invalid }
            return path
        }
    }

    public static func resourceID(_ descriptor: Wire.Resource) throws -> String {
        try validateResource(descriptor)
        return IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(descriptor)))
    }

    /// Captures an immutable, sealed resource descriptor in the same database
    /// transaction as its originating repository mutation.
    @discardableResult
    public static func registerResource(_ db: Database, descriptor: Wire.Resource) throws -> String {
        let id = try resourceID(descriptor)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM automaticSyncOperation WHERE entity='resource' AND entityID=? AND sourcePeer IS NULL)
            """, arguments: [id]) == true { return id }
        let json = String(decoding: try Wire.encode(descriptor), as: UTF8.self)
        try recordLocal(db, entity: .resource, id: id, field: "descriptor", value: json,
                        biometric: descriptor.kind == .voiceprint)
        try db.execute(sql: "DELETE FROM automaticSyncRevokedResource WHERE resourceID=?", arguments: [id])
        return id
    }

    @discardableResult
    public func registerResource(_ descriptor: Wire.Resource) async throws -> String {
        try await database.writer.write { db in try Self.registerResource(db, descriptor: descriptor) }
    }

    public func resource(id: String) async throws -> Wire.Resource? {
        try await database.reader.read { db in try Self.resource(db, id: id) }
    }

    public func resourcesNeedingDownload(
        from peerID: String, limit: Int = 32, includeBiometrics: Bool = true
    ) async throws -> [String] {
        try await database.reader.read { db in
            let consent = try Self.requirePeer(db, peerID: peerID)
            let candidates = try String.fetchAll(db, sql: """
                SELECT s.resourceID FROM automaticSyncResourceSource s
                WHERE s.peerID=? AND NOT EXISTS(SELECT 1 FROM automaticSyncResourcePayload p WHERE p.resourceID=s.resourceID)
                ORDER BY s.resourceID
                """, arguments: [peerID])
            var result: [String] = []
            for id in candidates {
                guard let descriptor = try Self.resource(db, id: id),
                      descriptor.kind != .voiceprint || (consent == .allowed && includeBiometrics) else { continue }
                if let path = try String.fetchOne(db, sql: "SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND verified=1", arguments: [id]),
                   FileManager.default.fileExists(atPath: path) { continue }
                result.append(id)
                if result.count >= max(1, min(limit, 256)) { break }
            }
            return result
        }
    }

    /// Verified bytes and application are separate durable commits. Retry these
    /// candidates at startup and after metadata changes, independently of downloads.
    /// A stale input can also mean dependencies have not arrived: retain it until
    /// successful application, revocation or deletion instead of discarding it.
    public func pendingApplications(peerID: String, includeBiometrics: Bool = true) async throws -> [String] {
        try await database.reader.read { db in
            let consent = try Self.requirePeer(db, peerID: peerID)
            let files = try Row.fetchAll(db, sql: """
                SELECT f.resourceID,f.localPath,f.fileName FROM automaticSyncResourceFile f
                JOIN automaticSyncResourceSource s ON s.resourceID=f.resourceID
                WHERE s.peerID=? AND f.verified=1 ORDER BY f.resourceID
                """, arguments: [peerID])
            return try files.compactMap { file in
                let id: String = file["resourceID"]
                guard let descriptor = try Self.resource(db, id: id),
                      descriptor.kind != .voiceprint || (consent == .allowed && includeBiometrics),
                      let path: String = file["localPath"],
                      FileManager.default.fileExists(atPath: path) else { return nil }
                let applied: Bool
                switch descriptor.kind {
                case .audio:
                    let meeting = try descriptor.meetingID.flatMap {
                        try Meeting.fetchOne(db, key: Self.localID(db, entity: .meeting, id: $0))
                    }
                    if meeting?.localAudioPurgedAt != nil { return nil }
                    applied = meeting?.audioFileName == (file["fileName"] as String)
                        && meeting?.audioSHA256 == descriptor.sha256
                        && meeting?.audioByteCount.map(Int64.init) == descriptor.byteCount
                case .analysis:
                    applied = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM automaticSyncAnalysisProvenance WHERE resourceID=?)
                        """, arguments: [id])!
                case .transcript:
                    applied = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM automaticSyncTranscriptPublication WHERE resourceID=?)
                        """, arguments: [id])!
                case .voiceprint:
                    applied = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM automaticSyncVoiceprintProvenance WHERE resourceID=?)
                        """, arguments: [id])!
                }
                return applied ? nil : id
            }
        }
    }

    /// Only verified content-addressed files may become eligible for publication.
    /// The supplied directory is application-owned, never a sender-provided path.
    /// Files are copied/hashed in bounded chunks. Revoke journals cleanup before
    /// removing the file; callers run collectRevokedFiles() at startup.
    public func installResource(id: String, from source: URL, directory: URL) async throws -> URL {
        guard let descriptor = try await resource(id: id) else { throw Wire.Failure.resourceUnavailable }
        try await database.reader.read { db in try Self.requireResourceConsent(db, id: id, descriptor: descriptor) }
        let root = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(descriptor.sha256 + (descriptor.kind == .audio ? ".m4a" : ""))
        let staging = root.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw Wire.Failure.resourceUnavailable }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        var hash = IncrementalSHA256()
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            guard Int64(hash.byteCount) <= descriptor.byteCount,
                  Int64(chunk.count) <= descriptor.byteCount - Int64(hash.byteCount) else { throw Wire.Failure.hashMismatch }
            hash.update(chunk)
            try output.write(contentsOf: chunk)
        }
        guard Int64(hash.byteCount) == descriptor.byteCount, hash.finalize() == descriptor.sha256 else { throw Wire.Failure.hashMismatch }
        try output.synchronize()
        try await database.writer.write { db in
            guard try Self.resource(db, id: id) == descriptor else { throw Wire.Failure.resourceUnavailable }
            try Self.requireResourceConsent(db, id: id, descriptor: descriptor)
            try AutomaticSyncResourceTransfer.publishVerified(staging, to: target, descriptor: descriptor)
            try db.execute(sql: """
                INSERT INTO automaticSyncResourceFile VALUES(?,?,1,?)
                ON CONFLICT(resourceID) DO UPDATE SET fileName=excluded.fileName,verified=1,localPath=excluded.localPath
                """, arguments: [id, target.lastPathComponent, target.path])
            if descriptor.kind == .audio,
               let peer = try String.fetchOne(db, sql: "SELECT sourcePeer FROM automaticSyncOperation WHERE entity='resource' AND entityID=? AND sourcePeer IS NOT NULL ORDER BY counter,id LIMIT 1", arguments: [id]) {
                try AutomaticSyncResourceTransfer.recordAudioImport(db, resourceID: id, peerID: peer)
            }
        }
        return target
    }

    /// Call after installing into the application's audio directory. This never
    /// rewrites an existing sealed audio identity or grants permission to purge it.
    public func adoptAudioResource(id: String) async throws {
        try await database.writer.write { db in
            guard let descriptor = try Self.resource(db, id: id), descriptor.kind == .audio,
                  let meetingID = descriptor.meetingID,
                  var meeting = try Meeting.fetchOne(db, key: Self.localID(db, entity: .meeting, id: meetingID)),
                  let file = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncResourceFile WHERE resourceID=? AND verified=1", arguments: [id]),
                  meeting.localAudioPurgedAt == nil else { throw Wire.Failure.resourceUnavailable }
            if let hash = meeting.audioSHA256, hash != descriptor.sha256 { throw Wire.Failure.immutableResource }
            guard let path: String = file["localPath"] else { throw Wire.Failure.resourceUnavailable }
            let source = URL(fileURLWithPath: path)
            let digest = try IncrementalSHA256.hashFile(at: source, chunkBytes: 65_536)
            guard digest.sha256 == descriptor.sha256, Int64(digest.byteCount) == descriptor.byteCount else { throw Wire.Failure.hashMismatch }
            // AudioFileStore deletes by filename. Give each meeting-resource its
            // own managed path, even when two descriptors share identical bytes.
            let target = source.deletingLastPathComponent().appendingPathComponent(id + ".m4a")
            try AutomaticSyncResourceTransfer.publishVerified(source, to: target, descriptor: descriptor)
            try db.execute(sql: "UPDATE automaticSyncResourceFile SET fileName=?,localPath=? WHERE resourceID=?",
                           arguments: [target.lastPathComponent, target.path, id])
            if source.path != target.path {
                try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncFileGarbage VALUES(?)", arguments: [source.path])
            }
            meeting.audioFileName = target.lastPathComponent
            meeting.audioSHA256 = descriptor.sha256
            meeting.audioByteCount = Int(descriptor.byteCount)
            try meeting.update(db)
        }
        try await collectRevokedFiles()
    }

    public func transcriptRevision(meetingID: String) async throws -> String {
        try await database.reader.read { db in try Self.transcriptRevision(db, meetingID: meetingID) }
    }

    /// Stale results remain addressable as immutable history but cannot replace
    /// output derived from the current transcript.
    public func publishResource(id: String) async throws {
        try await database.writer.write { db in
            guard let resource = try Self.resource(db, id: id), let rawMeeting = resource.meetingID,
                  let input = resource.inputRevision else { throw Wire.Failure.invalid }
            let meeting = try Self.localID(db, entity: .meeting, id: rawMeeting)
            if resource.kind == .transcript {
                guard resource.byteCount <= 16 * 1_024 * 1_024,
                     let path = try String.fetchOne(db, sql: "SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND verified=1", arguments: [id]),
                     FileManager.default.fileExists(atPath: path) else {
                   throw Wire.Failure.resourceUnavailable
                }
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                guard bytes.count == resource.byteCount,
                     IncrementalSHA256.hex(SHA256.hash(data: bytes)) == resource.sha256 else { throw Wire.Failure.hashMismatch }
                let payload = try JSONDecoder().decode(TranscriptPublication.self, from: bytes)
                guard Self.canonicalID(payload.meetingID) == Self.canonicalID(meeting), payload.inputRevision == input else { throw Wire.Failure.invalid }
                _ = try Self.applyTranscript(db, payload: payload, resourceID: id)
                return
            }
            guard try Self.transcriptRevision(db, meetingID: meeting) == input else { throw Wire.Failure.staleRevision }
            guard try Bool.fetchOne(db, sql: "SELECT verified FROM automaticSyncResourceFile WHERE resourceID=?", arguments: [id]) == true else {
                throw Wire.Failure.resourceUnavailable
            }
            if resource.kind == .analysis {
                guard resource.byteCount <= 16 * 1_024 * 1_024,
                      let path = try String.fetchOne(db, sql: "SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=?", arguments: [id]),
                      FileManager.default.fileExists(atPath: path) else {
                    throw Wire.Failure.resourceUnavailable
                }
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                guard bytes.count == resource.byteCount,
                      IncrementalSHA256.hex(SHA256.hash(data: bytes)) == resource.sha256 else { throw Wire.Failure.hashMismatch }
                let draft = try JSONDecoder().decode(AnalysisResultDraft.self, from: bytes)
                guard Self.canonicalID(draft.meetingId) == Self.canonicalID(meeting), Self.validID(draft.id),
                      Self.validID(draft.producedByDeviceId) else { throw Wire.Failure.invalid }
                if let existing = try Row.fetchOne(db, sql: "SELECT * FROM analysisResult WHERE id=?", arguments: [draft.id]) {
                    let provenance = try String.fetchOne(db, sql: "SELECT resourceID FROM automaticSyncAnalysisProvenance WHERE analysisID=?", arguments: [draft.id])
                    guard provenance == id, existing["payloadJSON"] as String == draft.payloadJSON else { throw Wire.Failure.equivocation }
                } else {
                    let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(revision),0)+1 FROM analysisResult WHERE meetingId=? AND kind=?",
                                                arguments: [meeting, draft.kind.rawValue])!
                    try db.execute(sql: """
                        INSERT INTO analysisResult(id,meetingId,kind,payloadJSON,producedByDeviceId,producedAt,revision)
                        VALUES(?,?,?,?,?,?,?)
                        """, arguments: [draft.id, meeting, draft.kind.rawValue, draft.payloadJSON, draft.producedByDeviceId, draft.producedAt, next])
                }
                try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncAnalysisProvenance VALUES(?,?,?)", arguments: [draft.id, id, input])
            }
            try db.execute(sql: """
                INSERT INTO automaticSyncPublication VALUES(?,?,?,?)
                ON CONFLICT(meetingID,kind) DO UPDATE SET resourceID=excluded.resourceID,inputRevision=excluded.inputRevision
                """, arguments: [meeting, resource.kind.rawValue, id, input])
        }
    }

    public func publishedResource(meetingID: String, kind: Wire.Resource.Kind) async throws -> String? {
        try await database.reader.read { db in
            let meetingID = try Self.localID(db, entity: .meeting, id: meetingID)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT resourceID,inputRevision FROM automaticSyncPublication WHERE meetingID=? AND kind=?
                """, arguments: [meetingID, kind.rawValue]),
                  try Self.transcriptRevision(db, meetingID: meetingID) == row["inputRevision"] as String else { return nil }
            return row["resourceID"]
        }
    }

    static func transcriptRevision(_ db: Database, meetingID: String) throws -> String {
        let fields = ["id", "startMs", "endMs", "text", "localeIdentifier", "engine", "revision", "confidence"]
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(fields.map { "CAST(CAST(u.\($0) AS TEXT) AS BLOB) AS \($0)" }.joined(separator: ","))
            FROM utterance u WHERE u.meetingId=? ORDER BY \(AutomaticSyncSchema.canonicalSQL("u.id"))
            """, arguments: [try localID(db, entity: .meeting, id: meetingID)])
        let snapshot = rows.map { row in fields.map { field -> String? in
            let value: String? = row[field]
            return field == "id" ? value.map(canonicalID) : value
        } }
        return IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(snapshot)))
    }

    static func resource(_ db: Database, id: String) throws -> Wire.Resource? {
        guard try !deleted(db, entity: .resource, id: id),
              try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM automaticSyncRevokedResource WHERE resourceID=?)", arguments: [id])!,
              let value = try values(db, entity: .resource, id: id)["descriptor"] else { return nil }
        let descriptor = try JSONDecoder().decode(Wire.Resource.self, from: Data(value.utf8))
        if descriptor.kind != .voiceprint, let meeting = descriptor.meetingID,
           try deleted(db, entity: .meeting, id: meeting) { return nil }
        if let speaker = descriptor.speakerID, try deleted(db, entity: .speaker, id: speaker) { return nil }
        return descriptor
    }

    static func requireResourceConsent(_ db: Database, id: String, descriptor: Wire.Resource) throws {
        guard descriptor.kind == .voiceprint else { return }
        let sources = try String.fetchAll(db, sql: "SELECT peerID FROM automaticSyncResourceSource WHERE resourceID=?", arguments: [id])
        for peer in sources {
            if (try? requirePeer(db, peerID: peer)) == .allowed { return }
        }
        let local = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM automaticSyncResourcePayload WHERE resourceID=?)
            """, arguments: [id]) ?? false
        guard local else { throw Wire.Failure.consentRequired }
    }

    static func validateResource(_ resource: Wire.Resource) throws {
        guard resource.sealed, resource.byteCount > 0, resource.byteCount <= 8 * 1_024 * 1_024 * 1_024,
              resource.sha256.count == 64, resource.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              resource.meetingID.map(validID) ?? true, resource.speakerID.map(validID) ?? true else { throw Wire.Failure.invalid }
        switch resource.kind {
        case .audio:
            guard resource.meetingID != nil, resource.speakerID == nil, resource.modelFingerprint == nil,
                  resource.preprocessing == nil, resource.dimensions == nil, resource.inputRevision == nil,
                  resource.sampleCount == nil else { throw Wire.Failure.invalid }
        case .voiceprint:
            guard resource.meetingID == nil, resource.inputRevision == nil,
                  resource.speakerID != nil, let dimension = resource.dimensions, (1...65_536).contains(dimension),
                  resource.byteCount == Int64(dimension * MemoryLayout<Float>.size),
                  resource.modelFingerprint.map(validID) ?? true,
                  resource.preprocessing.map(validID) ?? true,
                  resource.sampleCount.map({ $0 >= 0 }) ?? true else { throw Wire.Failure.invalid }
        case .analysis, .transcript:
            guard resource.speakerID == nil, resource.dimensions == nil, resource.sampleCount == nil,
                  resource.meetingID != nil, let revision = resource.inputRevision, validID(revision),
                  let model = resource.modelFingerprint, validID(model),
                  let preprocessing = resource.preprocessing, validID(preprocessing) else { throw Wire.Failure.invalid }
        }
    }
}
