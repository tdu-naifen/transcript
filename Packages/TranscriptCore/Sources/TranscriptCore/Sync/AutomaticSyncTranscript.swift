import CryptoKit
import Foundation
import GRDB

extension AutomaticSyncRepository {
    public struct ProcessingInput: Codable, Sendable, Equatable {
        public let meetingID: String
        public let audioSHA256: String
        /// Local-only fence, including identities and meeting-speaker links.
        public let revision: String
        /// Consent-independent content fence used by recipient publication.
        public let transcriptRevision: String
        public let sourceDurationMs: Int?
        public let sourceLocaleIdentifier: String?

        init(meetingID: String, audioSHA256: String, revision: String, transcriptRevision: String,
             sourceDurationMs: Int? = nil, sourceLocaleIdentifier: String? = nil) {
            self.meetingID = meetingID
            self.audioSHA256 = audioSHA256
            self.revision = revision
            self.transcriptRevision = transcriptRevision
            self.sourceDurationMs = sourceDurationMs
            self.sourceLocaleIdentifier = sourceLocaleIdentifier
        }
    }

    public struct PublishedTranscript: Codable, Sendable, Equatable {
        public let publicationID: String
        public let resourceID: String
        public let outputRevision: String
    }

    private struct ProcessingSnapshot: Encodable {
        let utterances: [Utterance]
        let links: [MeetingSpeaker]
        let speakers: [Speaker]
        let durationMs: Int
        let localeIdentifier: String?
    }

    /// Capture before reading the worker's snapshot; publication compares again
    /// inside its write transaction. Keep this token in the durable job manifest.
    public func captureProcessingInput(meetingID: String) async throws -> ProcessingInput {
        try await database.reader.read { db in
            try Self.captureProcessingInput(db, meetingID: meetingID)
        }
    }

    private static func captureProcessingInput(_ db: Database, meetingID: String) throws -> ProcessingInput {
        let id = try localID(db, entity: .meeting, id: meetingID)
        guard try !deleted(db, entity: .meeting, id: id),
              let meeting = try Meeting.fetchOne(db, key: id),
              meeting.localAudioPurgedAt == nil,
              let audioSHA256 = meeting.audioSHA256,
              audioSHA256.count == 64, audioSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Wire.Failure.staleRevision
        }
        let utterances = try Utterance.filter(Utterance.Columns.meetingId == id)
            .order(Column("id")).fetchAll(db)
        let links = try MeetingSpeaker.filter(MeetingSpeaker.Columns.meetingId == id)
            .order(MeetingSpeaker.Columns.speakerId).fetchAll(db)
        let speakerIDs = Set(utterances.compactMap(\.speakerId) + links.map(\.speakerId))
        let speakers = try Speaker.filter(speakerIDs.contains(Speaker.Columns.id))
            .order(Speaker.Columns.id).fetchAll(db)
        let snapshot = ProcessingSnapshot(utterances: utterances, links: links, speakers: speakers,
            durationMs: meeting.durationMs, localeIdentifier: meeting.localeIdentifier)
        return ProcessingInput(meetingID: id, audioSHA256: audioSHA256,
            revision: IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(snapshot))),
            transcriptRevision: try transcriptRevision(db, meetingID: id),
            sourceDurationMs: meeting.durationMs, sourceLocaleIdentifier: meeting.localeIdentifier)
    }

    /// A historical commit receipt, not a claim that this is still the current
    /// transcript. It survives later edits and enables crash recovery by job ID.
    public func transcriptPublication(publicationID: String) async throws -> PublishedTranscript? {
        try await database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncTranscriptPublication WHERE id=?",
                             arguments: [publicationID]).map {
                PublishedTranscript(publicationID: publicationID, resourceID: $0["resourceID"],
                                    outputRevision: $0["outputRevision"])
            }
        }
    }

    public func publishTranscript(
        input: ProcessingInput, utterances: [Utterance], publicationID: String,
        modelFingerprint: String, preprocessing: String, expectedUtterances: [Utterance]? = nil,
        speakerAnalysis: TranscriptSpeakerAnalysis? = nil
    ) async throws -> String {
        let fingerprint: String
        if let speakerAnalysis {
            let analysisDigest = IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(speakerAnalysis)))
            fingerprint = IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode([modelFingerprint, analysisDigest])))
        } else {
            fingerprint = modelFingerprint
        }
        return try await publishTranscript(meetingID: input.meetingID, expectedAudioSHA256: input.audioSHA256,
            expectedRevision: input.transcriptRevision, utterances: utterances, publicationID: publicationID,
            modelFingerprint: fingerprint, preprocessing: preprocessing, processingInput: input,
            expectedUtterances: expectedUtterances, speakerAnalysis: speakerAnalysis)
    }

    public struct TranscriptMapping: Codable, Sendable, Equatable {
        public let sourceID: String
        public let sourceRevision: Int
        public let sourceStartMs: Int
        public let sourceEndMs: Int
        public let targetID: String
    }

    struct TranscriptPublication: Codable, Sendable {
        let id: String
        let meetingID: String
        let audioSHA256: String
        let inputRevision: String
        let utterances: [Utterance]
        let mappings: [TranscriptMapping]
    }

    /// The input fence, replacement, revision mapping and immutable output all
    /// commit together. Retries return the original output without rewriting rows.
    /// Returns the output transcript revision; use `publishedResource` for its resource ID.
    public func publishTranscript(
        meetingID: String, expectedAudioSHA256: String, expectedRevision: String,
        utterances: [Utterance], publicationID: String,
        modelFingerprint: String, preprocessing: String, expectedUtterances: [Utterance]? = nil
    ) async throws -> String {
        try await publishTranscript(meetingID: meetingID, expectedAudioSHA256: expectedAudioSHA256,
            expectedRevision: expectedRevision, utterances: utterances, publicationID: publicationID,
            modelFingerprint: modelFingerprint, preprocessing: preprocessing, processingInput: nil,
            expectedUtterances: expectedUtterances, speakerAnalysis: nil)
    }

    private func publishTranscript(
        meetingID: String, expectedAudioSHA256: String, expectedRevision: String,
        utterances: [Utterance], publicationID: String,
        modelFingerprint: String, preprocessing: String, processingInput: ProcessingInput?,
        expectedUtterances: [Utterance]?, speakerAnalysis: TranscriptSpeakerAnalysis?
    ) async throws -> String {
        try await database.writer.write { db in
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncTranscriptPublication WHERE id=?", arguments: [publicationID]) {
                let id: String = existing["resourceID"]
                guard let descriptor = try Self.resource(db, id: id),
                      descriptor.inputRevision == expectedRevision, descriptor.modelFingerprint == modelFingerprint,
                      descriptor.preprocessing == preprocessing,
                      let bytes = try Data.fetchOne(db, sql: "SELECT bytes FROM automaticSyncResourcePayload WHERE resourceID=?", arguments: [id]) else {
                    throw Wire.Failure.equivocation
                }
                let payload = try JSONDecoder().decode(TranscriptPublication.self, from: bytes)
                guard Self.canonicalID(payload.meetingID) == Self.canonicalID(meetingID),
                      payload.audioSHA256 == expectedAudioSHA256,
                      try Wire.encode(payload.utterances) == Wire.encode(utterances) else { throw Wire.Failure.equivocation }
                return existing["outputRevision"]
            }
            if let processingInput {
                let currentInput = try Self.captureProcessingInput(db, meetingID: meetingID)
                if currentInput.revision != processingInput.revision
                    || currentInput.meetingID != processingInput.meetingID
                    || currentInput.audioSHA256 != processingInput.audioSHA256
                    || currentInput.transcriptRevision != processingInput.transcriptRevision {
                    guard processingInput.sourceDurationMs != nil,
                          currentInput.meetingID == processingInput.meetingID,
                          currentInput.audioSHA256 == processingInput.audioSHA256,
                          currentInput.sourceDurationMs == processingInput.sourceDurationMs,
                          currentInput.sourceLocaleIdentifier == processingInput.sourceLocaleIdentifier,
                          let expectedUtterances,
                          try Self.contentMatchesInput(db, meetingID: meetingID, expected: expectedUtterances,
                                                      revision: expectedRevision) else {
                        throw Wire.Failure.staleRevision
                    }
                }
            }
            let meeting = try Self.localID(db, entity: .meeting, id: meetingID)
            let previous = try Utterance.filter(Utterance.Columns.meetingId == meeting).fetchAll(db)
            let compatibleContent = try expectedUtterances.map {
                try Self.contentMatchesInput(db, meetingID: meeting, expected: $0, revision: expectedRevision)
            } ?? false
            guard try Self.transcriptRevision(db, meetingID: meeting) == expectedRevision || compatibleContent else {
                throw Wire.Failure.staleRevision
            }
            if let expectedUtterances,
               try Self.transcriptSnapshot(previous) != Self.transcriptSnapshot(expectedUtterances), !compatibleContent {
                throw Wire.Failure.staleRevision
            }
            let mappings = (expectedUtterances ?? previous).flatMap { source in
                utterances.filter { $0.startMs < source.endMs && $0.endMs > source.startMs }.map {
                    TranscriptMapping(sourceID: source.id, sourceRevision: source.revision,
                                      sourceStartMs: source.startMs, sourceEndMs: source.endMs, targetID: $0.id)
                }
            }
            let payload = TranscriptPublication(id: publicationID, meetingID: meetingID,
                audioSHA256: expectedAudioSHA256, inputRevision: expectedRevision,
                utterances: utterances, mappings: mappings)
            let bytes = try Wire.encode(payload)
            guard bytes.count <= 16 * 1_024 * 1_024 else { throw Wire.Failure.invalid }
            let descriptor = Wire.Resource(kind: .transcript, meetingID: meetingID,
                sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count),
                modelFingerprint: modelFingerprint, preprocessing: preprocessing, inputRevision: expectedRevision)
            let id = try Self.registerResource(db, descriptor: descriptor)
            let revision = try Self.applyTranscript(db, payload: payload, resourceID: id, exportBiometrics: true)
            if let speakerAnalysis {
                try Self.applySpeakerAnalysis(db, analysis: speakerAnalysis, meetingID: meeting, resourceID: id)
                let assigned = try Utterance.filter(Utterance.Columns.meetingId == meeting).order(Column("id")).fetchAll(db)
                try db.execute(sql: "UPDATE automaticSyncTranscriptHead SET utterances=? WHERE meetingID=?",
                               arguments: [try Self.transcriptSnapshot(assigned), meeting])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncResourcePayload VALUES(?,?)", arguments: [id, bytes])
            return revision
        }
    }

    public func transcriptMappings(publicationID: String) async throws -> [TranscriptMapping] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM automaticSyncTranscriptMapping WHERE publicationID=? ORDER BY sourceID,targetID",
                             arguments: [publicationID]).map {
                TranscriptMapping(sourceID: $0["sourceID"], sourceRevision: $0["sourceRevision"],
                    sourceStartMs: $0["sourceStartMs"], sourceEndMs: $0["sourceEndMs"], targetID: $0["targetID"])
            }
        }
    }

    static func applyTranscript(_ db: Database, payload: TranscriptPublication, resourceID: String,
                                exportBiometrics: Bool = false) throws -> String {
        if let existing = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncTranscriptPublication WHERE id=?", arguments: [payload.id]) {
            guard existing["resourceID"] as String == resourceID else { throw Wire.Failure.equivocation }
            return existing["outputRevision"]
        }
        let meetingID = try localID(db, entity: .meeting, id: payload.meetingID)
        guard validID(payload.id), try !deleted(db, entity: .meeting, id: meetingID),
              let meeting = try Meeting.fetchOne(db, key: meetingID),
              meeting.audioSHA256 == payload.audioSHA256 else { throw Wire.Failure.staleRevision }
        guard !payload.utterances.isEmpty, payload.utterances.count <= 100_000,
              Set(payload.utterances.map { canonicalID($0.id) }).count == payload.utterances.count,
              payload.utterances.allSatisfy({
                  validID($0.id) && canonicalID($0.meetingId) == canonicalID(meetingID)
                    && $0.speakerId == nil && $0.startMs >= 0 && $0.endMs >= $0.startMs
                    && $0.endMs <= meeting.durationMs + 3_000 && $0.revision > 0
                    && $0.text.utf8.count <= 524_288
                    && ($0.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
              }) else { throw Wire.Failure.invalid }
        let current = try Utterance.filter(Utterance.Columns.meetingId == meetingID).order(Column("id")).fetchAll(db)
        let currentRevision = try transcriptRevision(db, meetingID: meetingID)
        let compatibleInput = currentRevision == payload.inputRevision ? current
            : try inputWithCurrentIdentities(db, current: current, payload: payload)
        let matchesInput = compatibleInput != nil
        let head = try Row.fetchOne(db, sql: "SELECT * FROM automaticSyncTranscriptHead WHERE meetingID=?", arguments: [meetingID])
        let headPath = try head.map { try JSONDecoder().decode([String].self, from: $0["path"]) } ?? []
        let previous: [Utterance]
        let parentPath: [String]
        if let compatibleInput {
            previous = compatibleInput
            if let savedPath = try Data.fetchOne(db, sql: """
                SELECT path FROM automaticSyncTranscriptRevision WHERE meetingID=? AND revision=?
                """, arguments: [meetingID, payload.inputRevision]),
               savedPath == (try Wire.encode(headPath)) {
                parentPath = headPath
            } else {
                // A publication explicitly based on edited input starts a new
                // generation. An old sibling cannot later erase that edit by
                // winning the previous generation's branch comparison.
                parentPath = [payload.inputRevision]
            }
        } else if let base = try Row.fetchOne(db, sql: """
            SELECT * FROM automaticSyncTranscriptRevision WHERE meetingID=? AND revision=?
            """, arguments: [meetingID, payload.inputRevision]) {
            previous = try JSONDecoder().decode([Utterance].self, from: base["utterances"])
            parentPath = try JSONDecoder().decode([String].self, from: base["path"])
        } else { throw Wire.Failure.staleRevision }
        // Mapping claims are not evidence: derive the complete overlap relation
        // from the saved input rows, including Unknown and partial intersections.
        let expectedMappings = previous.flatMap { source in
            payload.utterances.filter { $0.startMs < source.endMs && $0.endMs > source.startMs }.map {
                TranscriptMapping(sourceID: source.id, sourceRevision: source.revision,
                    sourceStartMs: source.startMs, sourceEndMs: source.endMs, targetID: $0.id)
            }
        }
        func mappingBytes(_ mappings: [TranscriptMapping]) throws -> [Data] {
            try mappings.map { try Wire.encode(TranscriptMapping(sourceID: canonicalID($0.sourceID),
                sourceRevision: $0.sourceRevision, sourceStartMs: $0.sourceStartMs,
                sourceEndMs: $0.sourceEndMs, targetID: canonicalID($0.targetID))) }
                .sorted { $0.lexicographicallyPrecedes($1) }
        }
        guard try mappingBytes(payload.mappings) == mappingBytes(expectedMappings),
              Set(previous.map { canonicalID($0.id) }).isDisjoint(with: payload.utterances.map { canonicalID($0.id) })
        else { throw Wire.Failure.invalid }
        for utterance in payload.utterances {
            // An edit may precede its artifact, but another artifact may not
            // claim a previously published target identity as its own output.
            guard try !Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                WHERE r.entity='utterance' AND r.entityID=? AND o.sourcePeer GLOB 'publication:*')
                """, arguments: [canonicalID(utterance.id)])! else { throw Wire.Failure.invalid }
        }
        let path = parentPath + [resourceID]
        if !matchesInput, path.first != headPath.first { throw Wire.Failure.staleRevision }
        // Resource IDs are ASCII hashes. Compare at the first branch divergence;
        // extending a winning branch beats its ancestor, not a higher sibling.
        let selected = matchesInput || headPath.lexicographicallyPrecedes(path)
        if selected, !matchesInput {
            guard let head, !(head["protected"] as Bool),
                  try transcriptHeadIsUnedited(db, current: current, snapshot: head["utterances"],
                                              resourceID: headPath.last!) else { throw Wire.Failure.staleRevision }
        }
        var replacement = payload.utterances
        for index in replacement.indices {
            replacement[index].meetingId = meetingID
            replacement[index].speakerId = inheritedSpeaker(target: replacement[index], sources: previous)
        }
        let pureOutput = try transcriptRevision(db, utterances: replacement)
        try saveTranscriptRevision(db, meetingID: meetingID, revision: payload.inputRevision,
                                   utterances: previous, path: parentPath)
        try saveTranscriptRevision(db, meetingID: meetingID, revision: pureOutput, utterances: replacement, path: path)
        var output = pureOutput
        if selected {
            let applying = try Int.fetchOne(db, sql: "SELECT applying FROM automaticSyncState WHERE id=1")!
            try db.execute(sql: "UPDATE automaticSyncState SET applying=1 WHERE id=1")
            // Projection is not a new local edit. Baseline registers are derived
            // from the immutable descriptor; existing target edits always survive.
            let descriptor = try Row.fetchOne(db, sql: """
                SELECT o.* FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                WHERE r.entity='resource' AND r.entityID=? AND r.field='descriptor'
                """, arguments: [resourceID])!
            let stamp = operation(descriptor).stamp
            if matchesInput, currentRevision != payload.inputRevision {
                try mapIdentityRefinements(db, current: current, payload: payload, resourceID: resourceID)
            }
            for old in current {
                try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncTombstone VALUES('utterance',?)",
                               arguments: [canonicalID(old.id)])
            }
            try db.execute(sql: "DELETE FROM utterance WHERE meetingId=?", arguments: [meetingID])
            var protected = false
            if let head, parentPath == headPath, let previousResource = headPath.last {
                protected = try (head["protected"] as Bool) || !transcriptHeadIsUnedited(
                    db, current: current, snapshot: head["utterances"], resourceID: previousResource)
            }
            for utterance in replacement {
                if try deleted(db, entity: .utterance, id: utterance.id) {
                    protected = true
                    continue
                }
                guard try Utterance.fetchOne(db, key: localID(db, entity: .utterance, id: utterance.id)) == nil else {
                    throw Wire.Failure.invalid
                }
                try utterance.insert(db)
                let names = AutomaticSyncSchema.fields[.utterance]!
                let row = try Row.fetchOne(db, sql: """
                    SELECT \(names.map { "CAST(CAST(\($0) AS TEXT) AS BLOB) AS \($0)" }.joined(separator: ","))
                    FROM utterance WHERE id=?
                    """, arguments: [utterance.id])!
                for field in names {
                    if let existing = try Row.fetchOne(db, sql: """
                        SELECT o.* FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                        WHERE r.entity='utterance' AND r.entityID=? AND r.field=?
                        """, arguments: [canonicalID(utterance.id), field]) {
                        let inferred = try isInferredIdentityOperation(existing["id"],
                            resourceID: resourceID, utteranceID: utterance.id, value: existing["value"])
                        protected = protected || !(field == "speakerId" && inferred)
                        continue
                    }
                    let value: String? = row[field]
                    if field == "speakerId" {
                        // Absence is not a clear. Only the originating publisher
                        // exports inferred identities, under separate consent.
                        if exportBiometrics, let value {
                            try store(db, operation: .init(stamp: .init(counter: stamp.counter, deviceID: stamp.deviceID,
                                operationID: try inferredIdentityOperationID(resourceID: resourceID, utteranceID: utterance.id, value: value)),
                                entity: .utterance, entityID: utterance.id, field: field, value: value, biometric: true), sourcePeer: nil)
                            continue
                        }
                        if value == nil { continue }
                    }
                    let operationID = "publication-" + IncrementalSHA256.hex(SHA256.hash(data:
                        try Wire.encode([resourceID, canonicalID(utterance.id), field])))
                    try store(db, operation: .init(stamp: .init(counter: stamp.counter, deviceID: stamp.deviceID,
                        operationID: operationID), entity: .utterance, entityID: utterance.id, field: field,
                        value: value, biometric: field == "speakerId"), sourcePeer: "publication:\(payload.id)")
                }
            }
            try materialize(db, affected: [.utterance: Set(replacement.map { canonicalID($0.id) })])
            output = try transcriptRevision(db, meetingID: meetingID)
            let applied = try Utterance.filter(Utterance.Columns.meetingId == meetingID).order(Column("id")).fetchAll(db)
            try db.execute(sql: """
                INSERT INTO automaticSyncTranscriptHead VALUES(?,?,?,?)
                ON CONFLICT(meetingID) DO UPDATE SET path=excluded.path,utterances=excluded.utterances,protected=excluded.protected
                """, arguments: [meetingID, try Wire.encode(path), try transcriptSnapshot(applied), protected])
            try db.execute(sql: "UPDATE automaticSyncState SET applying=? WHERE id=1", arguments: [applying])
            try db.execute(sql: """
                INSERT INTO automaticSyncPublication VALUES(?,'transcript',?,?)
                ON CONFLICT(meetingID,kind) DO UPDATE SET resourceID=excluded.resourceID,inputRevision=excluded.inputRevision
                """, arguments: [meetingID, resourceID, output])
        }
        for mapping in payload.mappings {
            try db.execute(sql: "INSERT INTO automaticSyncTranscriptMapping VALUES(?,?,?,?,?,?)",
                arguments: [payload.id, mapping.sourceID, mapping.sourceRevision,
                            mapping.sourceStartMs, mapping.sourceEndMs, mapping.targetID])
        }
        try db.execute(sql: "INSERT INTO automaticSyncTranscriptPublication VALUES(?,?,?)", arguments: [payload.id, resourceID, output])
        return output
    }

    private static func inheritedSpeaker(target: Utterance, sources: [Utterance]) -> String? {
        let overlaps = sources.filter { $0.startMs < target.endMs && $0.endMs > target.startMs }
            .sorted { $0.startMs < $1.startMs }
        guard target.endMs > target.startMs, let identity = overlaps.first?.speakerId,
              overlaps.allSatisfy({ $0.speakerId.map(canonicalID) == canonicalID(identity) }) else { return nil }
        var frontier = target.startMs
        for source in overlaps {
            let start = max(target.startMs, source.startMs), end = min(target.endMs, source.endMs)
            guard start <= frontier else { return nil }
            frontier = max(frontier, end)
        }

        return frontier >= target.endMs ? identity : nil
    }

    private static func inputWithCurrentIdentities(
        _ db: Database, current: [Utterance], payload: TranscriptPublication
    ) throws -> [Utterance]? {
        var sources: [String: TranscriptMapping] = [:]
        for mapping in payload.mappings {
            let id = canonicalID(mapping.sourceID)
            if let previous = sources[id],
               previous.sourceRevision != mapping.sourceRevision
                || previous.sourceStartMs != mapping.sourceStartMs
                || previous.sourceEndMs != mapping.sourceEndMs { return nil }
            sources[id] = mapping
        }
        var input = current
        for index in input.indices {
            guard let source = sources[canonicalID(input[index].id)] else { continue }
            guard source.sourceRevision > 0, input[index].revision >= source.sourceRevision,
                  input[index].startMs == source.sourceStartMs,
                  input[index].endMs == source.sourceEndMs else { return nil }
            input[index].revision = source.sourceRevision
        }
        // Identity assignment also increments the legacy row revision. Normalize
        // only that counter, then prove ALL non-biometric input fields still match
        // the immutable input hash. Keep current identities for overlap inheritance.
        return try transcriptRevision(db, utterances: input) == payload.inputRevision ? input : nil
    }

    private static func contentMatchesInput(
        _ db: Database, meetingID: String, expected: [Utterance], revision: String
    ) throws -> Bool {
        let id = try localID(db, entity: .meeting, id: meetingID)
        var current = try Utterance.filter(Utterance.Columns.meetingId == id).fetchAll(db)
        guard current.count == expected.count,
              Set(expected.map { canonicalID($0.id) }).count == expected.count else { return false }
        let revisions = Dictionary(uniqueKeysWithValues: expected.map { (canonicalID($0.id), $0.revision) })
        for index in current.indices {
            guard let original = revisions[canonicalID(current[index].id)], current[index].revision >= original else { return false }
            current[index].revision = original
        }
        return try transcriptRevision(db, utterances: current) == revision
    }

    private static func mapIdentityRefinements(
        _ db: Database, current: [Utterance], payload: TranscriptPublication, resourceID: String
    ) throws {
        let rows = Dictionary(uniqueKeysWithValues: current.map { (canonicalID($0.id), $0) })
        for target in payload.utterances {
            var refinements: [Wire.Operation] = []
            for mapping in payload.mappings where canonicalID(mapping.targetID) == canonicalID(target.id) {
                guard let source = rows[canonicalID(mapping.sourceID)],
                      source.revision > mapping.sourceRevision,
                      let row = try Row.fetchOne(db, sql: """
                        SELECT o.* FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                        WHERE r.entity='utterance' AND r.entityID=? AND r.field='speakerId'
                        """, arguments: [canonicalID(source.id)]) else { continue }
                refinements.append(operation(row))
            }
            guard let latest = refinements.max(by: { $0.stamp < $1.stamp }) else { continue }
            let value = inheritedSpeaker(target: target, sources: current)
            let identity = [resourceID, canonicalID(target.id), value] + refinements.map(\.id).sorted().map(Optional.some)
            let id = "mapped-" + IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(identity)))
            // Re-segmentation maps an existing correction, not a new model guess.
            // Reuse its causal stamp; explicit target edits still win normally.
            try store(db, operation: .init(
                stamp: .init(counter: latest.stamp.counter, deviceID: latest.stamp.deviceID, operationID: id),
                entity: .utterance, entityID: target.id, field: "speakerId", value: value, biometric: true),
                sourcePeer: nil)
        }
    }

    private static func transcriptSnapshot(_ utterances: [Utterance]) throws -> Data {
        try Wire.encode(utterances.sorted { canonicalID($0.id).utf8.lexicographicallyPrecedes(canonicalID($1.id).utf8) })
    }

    static func inferredIdentityOperationID(
        resourceID: String, utteranceID: String, value: String?
    ) throws -> String {
        let key = [resourceID, canonicalID(utteranceID), value]
        return "inferred-" + IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(key)))
    }

    private static func isInferredIdentityOperation(
        _ operationID: String, resourceID: String, utteranceID: String, value: String?
    ) throws -> Bool {
        try operationID == inferredIdentityOperationID(resourceID: resourceID, utteranceID: utteranceID, value: value)
    }

    private static func transcriptHeadIsUnedited(_ db: Database, current: [Utterance], snapshot: Data,
                                                resourceID: String) throws -> Bool {
        let saved = try JSONDecoder().decode([Utterance].self, from: snapshot)
        let savedByID = Dictionary(uniqueKeysWithValues: saved.map { (canonicalID($0.id), $0) })
        var normalized = current
        for index in normalized.indices {
            let id = normalized[index].id
            guard let previous = savedByID[canonicalID(id)] else { return false }
            if let operation = try Row.fetchOne(db, sql: """
                SELECT o.* FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                WHERE r.entity='utterance' AND r.entityID=? AND r.field='speakerId'
                """, arguments: [canonicalID(id)]),
               try isInferredIdentityOperation(operation["id"], resourceID: resourceID, utteranceID: id, value: operation["value"]) {
                normalized[index].speakerId = previous.speakerId
            }
        }
        return try transcriptSnapshot(normalized) == snapshot
    }

    private static func saveTranscriptRevision(_ db: Database, meetingID: String, revision: String,
                                              utterances: [Utterance], path: [String]) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncTranscriptRevision VALUES(?,?,?,?)",
                       arguments: [meetingID, revision, try transcriptSnapshot(utterances), try Wire.encode(path)])
    }

    private static func transcriptRevision(_ db: Database, utterances: [Utterance]) throws -> String {
        // Use the same SQLite numeric/text conversions as the live-row hash.
        let snapshot = try utterances.sorted { canonicalID($0.id).utf8.lexicographicallyPrecedes(canonicalID($1.id).utf8) }.map { u in
            let arguments: StatementArguments = [canonicalID(u.id), u.startMs, u.endMs, databaseText(u.text),
                u.localeIdentifier, u.engine.rawValue, u.revision, u.confidence]
            let row = try Row.fetchOne(db, sql: "SELECT " + (0..<8).map { "CAST(CAST(? AS TEXT) AS BLOB) AS c\($0)" }.joined(separator: ","),
                                      arguments: arguments)!
            return (0..<8).map { row["c\($0)"] as String? }
        }
        return IncrementalSHA256.hex(SHA256.hash(data: try Wire.encode(snapshot)))
    }
}
