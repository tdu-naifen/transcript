import Foundation
import GRDB
import Synchronization

/// Revocation is synchronous and independent of a non-cancellable native prediction.
/// Only bounded database transactions hold this lock; inference never does.
public final class LiveSpeakerAuthorization: Sendable {
    private struct State { var generation = 0; var active = true; var closed = false }
    private let state = Mutex(State())
    public init() {}
    public var generation: Int? { state.withLock { $0.active && !$0.closed ? $0.generation : nil } }
    public func setActive(_ active: Bool) {
        state.withLock {
            guard !$0.closed, $0.active != active else { return }
            $0.active = active
            $0.generation += 1
        }
    }
    public func close() { state.withLock { $0.closed = true; $0.active = false; $0.generation += 1 } }
    func authorize<T>(_ generation: Int, _ operation: () throws -> T) throws -> T {
        try state.withLock {
            guard $0.active, !$0.closed, $0.generation == generation else { throw CancellationError() }
            try Task.checkCancellation()
            return try operation()
        }
    }
}

struct LiveSpeakerIdentity: Sendable {
    let id: String
    let ordinal: Int
}

struct LiveSpeakerVoice: Sendable {
    let identityID: String
    let embedding: [Float]
    let cleanFrameCount: Int
}

struct LiveSpeakerPublication: Sendable {
    let bound: Set<String>
    let capacityLimited: Bool
}

struct LiveSpeakerRepository: Sendable {
    let database: AppDatabase
    let meetingID: String
    let epoch: String
    let deviceID: String
    let authorization: LiveSpeakerAuthorization

    private func check(_ db: Database, allowSealed: Bool = false) throws {
        guard let meeting = try Meeting.fetchOne(db, key: meetingID), allowSealed || meeting.state == .recording,
              try String.fetchOne(db, sql: "SELECT state FROM speakerAnalysisJob WHERE meetingId = ?", arguments: [meetingID]) == nil else {
            throw VoiceprintBindingError.staleExpectation
        }
    }

    private func transaction<T: Sendable>(
        generation: Int?, _ operation: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        let started = ContinuousClock.now
        let result = try await database.writer.writeWithoutTransaction { db in
            func perform() throws -> T {
                var value: T?
                try db.inTransaction {
                    try check(db, allowSealed: generation == nil)
                    value = try operation(db)
                    try Task.checkCancellation()
                    return .commit
                }
                return value!
            }
            if let generation { return try authorization.authorize(generation, perform) }
            return try perform()
        }
        LiveSpeakerTiming.record(.transactionCommit, since: started)
        return result
    }

    func begin(generation: Int) async throws {
        try await transaction(generation: generation) { db in
            try db.execute(sql: """
                INSERT INTO liveSpeakerSession(meetingId, epoch) VALUES (?, ?)
                ON CONFLICT(meetingId) DO UPDATE SET epoch = excluded.epoch, frontier = 0, bindingRevision = 0
                WHERE liveSpeakerSession.epoch != excluded.epoch
                """, arguments: [meetingID, epoch])
        }
    }

    func publish(
        generation: Int, identities: [LiveSpeakerIdentity], spans: [LiveSpeakerSpan],
        voices: [LiveSpeakerVoice], modelIdentifier: String
    ) async throws -> LiveSpeakerPublication {
        guard identities.count <= 256, spans.count <= 1_024, voices.count <= 2,
              Set(identities.map(\.id)).count == identities.count,
              identities.allSatisfy({ UUID(uuidString: $0.id) != nil && (0..<256).contains($0.ordinal) }),
              !modelIdentifier.isEmpty else { throw EvidenceError.bounds }
        return try await transaction(generation: generation) { db in
            guard let session = try Row.fetchOne(db, sql: "SELECT * FROM liveSpeakerSession WHERE meetingId = ? AND epoch = ?", arguments: [meetingID, epoch]) else {
                throw VoiceprintBindingError.staleExpectation
            }
            var frontier: Int64 = session["frontier"]
            for identity in identities {
                try db.execute(sql: """
                    INSERT INTO liveSpeakerIdentity(id, meetingId, epoch, ordinal) VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: [identity.id, meetingID, epoch, identity.ordinal])
            }
            let validIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM liveSpeakerIdentity WHERE meetingId = ? AND epoch = ?", arguments: [meetingID, epoch]))
            for span in spans {
                guard span.startTick == frontier, span.endTick > span.startTick,
                      !span.unknown || span.identityID == nil,
                      span.identityID.map(validIDs.contains) ?? true else { throw EvidenceError.geometry }
                try db.execute(sql: """
                    INSERT INTO liveSpeakerSpan(meetingId, epoch, startTick, endTick, identityId, unknown)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [meetingID, epoch, span.startTick, span.endTick, span.identityID, span.unknown])
                frontier = span.endTick
            }
            let bindingStarted = ContinuousClock.now
            let policy = VoiceprintMatchPolicy()
            var speakerCount = voices.isEmpty ? 0 : try Speaker.fetchCount(db)
            let templateCount = voices.isEmpty ? 0 : try SpeakerEmbedding
                .filter(SpeakerEmbedding.Columns.modelIdentifier == modelIdentifier).fetchCount(db)
            var capacityLimited = speakerCount > LiveSpeakerLimits.bankEntries || templateCount > LiveSpeakerLimits.bankEntries
            let canBind = !voices.isEmpty && !capacityLimited
            var bank = canBind ? try SpeakerEmbedding
                .filter(SpeakerEmbedding.Columns.modelIdentifier == modelIdentifier)
                .filter(SpeakerEmbedding.Columns.preprocessing == VoiceprintPreprocessing.campPlus).fetchAll(db) : []
            var usedNames = canBind ? Set(try String.fetchAll(db, sql: "SELECT anonymousName FROM speaker")) : Set<String>()
            var bound = Set(try String.fetchAll(db, sql: """
                SELECT id FROM liveSpeakerIdentity WHERE meetingId = ? AND epoch = ? AND speakerId IS NOT NULL
                """, arguments: [meetingID, epoch]))
            var changed = false
            for voice in voices where canBind && !bound.contains(voice.identityID) {
                guard validIDs.contains(voice.identityID), (32_000...80_000).contains(voice.cleanFrameCount),
                      voice.embedding.count == 192, let vector = FloatVector.normalized(voice.embedding) else {
                    throw VoiceprintBindingError.invalidEmbedding
                }
                var scores: [String: Float] = [:]
                for template in bank where template.dimension == 192 {
                    guard let candidate = FloatVector.normalized(template.floats) else { continue }
                    let score = zip(vector, candidate).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                    scores[template.speakerId] = max(score, scores[template.speakerId] ?? -.infinity)
                }
                var ranked: [VoiceprintCandidate] = scores.map { VoiceprintCandidate(speakerId: $0.key, score: $0.value) }
                ranked.sort { first, second in
                    if first.score == second.score { return first.speakerId < second.speakerId }
                    return first.score > second.score
                }
                let chosen: Speaker
                if case .matched(let id, _) = policy.evaluate(
                    candidates: Array(ranked.prefix(2)), cleanDuration: Double(voice.cleanFrameCount) / 16_000, generation: 0
                ), let speaker = try Speaker.fetchOne(db, key: id) {
                    chosen = speaker
                } else {
                    // A high-scoring tie is not evidence of a new person.
                    if (ranked.first?.score ?? -1) >= policy.minimumSimilarity { continue }
                    guard speakerCount < LiveSpeakerLimits.bankEntries, bank.count < LiveSpeakerLimits.bankEntries else {
                        capacityLimited = true
                        continue
                    }
                    let name = AnonymousNameGenerator.nextName(usedNames: Array(usedNames))
                    usedNames.insert(name)
                    chosen = Speaker(anonymousName: name, colorIndex: try Speaker.fetchCount(db) % 12, originDeviceId: deviceID)
                    try chosen.insert(db)
                    speakerCount += 1
                    let template = SpeakerEmbedding(speakerId: chosen.id, floats: vector, originDeviceId: deviceID, modelIdentifier: modelIdentifier,
                                                    preprocessing: VoiceprintPreprocessing.campPlus)
                    try template.insert(db)
                    try AutomaticSyncRepository.captureVoiceprint(db, embedding: template)
                    bank.append(template)
                }
                try db.execute(sql: "UPDATE liveSpeakerIdentity SET speakerId = ? WHERE id = ?", arguments: [chosen.id, voice.identityID])
                let linked = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM meetingSpeaker WHERE meetingId = ? AND speakerId = ?)", arguments: [meetingID, chosen.id]) ?? false
                if !linked {
                    let index = (try Int.fetchOne(db, sql: "SELECT MAX(displayIndex) FROM meetingSpeaker WHERE meetingId = ?", arguments: [meetingID]) ?? -1) + 1
                    try MeetingSpeaker(meetingId: meetingID, speakerId: chosen.id, displayIndex: index, originDeviceId: deviceID).insert(db)
                }
                bound.insert(voice.identityID)
                changed = true
            }
            LiveSpeakerTiming.record(.identityBinding, since: bindingStarted)
            try db.execute(sql: """
                UPDATE liveSpeakerSession SET frontier = ?, bindingRevision = bindingRevision + ? WHERE meetingId = ? AND epoch = ?
                """, arguments: [frontier, changed ? 1 : 0, meetingID, epoch])
            return LiveSpeakerPublication(bound: bound, capacityLimited: capacityLimited)
        }
    }

    /// Paged persisted projection also catches late ASR without retaining transcript history.
    func reconcile(generation: Int?) async throws {
        while try await reconcilePage(generation: generation) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    @discardableResult
    func reconcilePage(generation: Int?) async throws -> Bool {
        try await transaction(generation: generation) { db in
            guard let session = try Row.fetchOne(db, sql: "SELECT * FROM liveSpeakerSession WHERE meetingId = ? AND epoch = ?", arguments: [meetingID, epoch]) else {
                throw VoiceprintBindingError.staleExpectation
            }
            let revision: Int = session["bindingRevision"]
            let frontier: Int64 = session["frontier"]
            let ticksPerMs = LiveSpeakerLimits.ticksPerSecond / 1_000
            let rows = try Utterance.fetchAll(db, sql: """
                SELECT u.* FROM utterance u LEFT JOIN liveSpeakerChecked c ON c.utteranceId = u.id
                WHERE u.meetingId = ? AND u.speakerId IS NULL AND u.revision = 1
                AND u.startMs >= 0 AND u.endMs > u.startMs AND u.endMs <= ?
                AND (c.utteranceId IS NULL OR c.epoch != ? OR c.bindingRevision != ?)
                ORDER BY u.endMs, u.id LIMIT 128
                """, arguments: [meetingID, frontier / ticksPerMs, epoch, revision])
            for var utterance in rows {
                let lower = Int64(utterance.startMs) * ticksPerMs
                let upper = Int64(utterance.endMs) * ticksPerMs
                let evidence = try Row.fetchOne(db, sql: """
                    SELECT SUM(MIN(s.endTick, ?) - MAX(s.startTick, ?)) AS covered,
                        SUM(CASE WHEN s.unknown OR (s.identityId IS NOT NULL AND i.speakerId IS NULL) THEN 1 ELSE 0 END) AS invalid,
                        COUNT(DISTINCT i.speakerId) AS identityCount, MIN(i.speakerId) AS speaker,
                        COUNT(*) AS spanCount
                    FROM (SELECT * FROM liveSpeakerSpan WHERE meetingId = ? AND epoch = ?
                        AND startTick < ? AND endTick > ? ORDER BY startTick LIMIT ?) s
                    LEFT JOIN liveSpeakerIdentity i ON i.id = s.identityId
                    """, arguments: [upper, lower, meetingID, epoch, upper, lower, LiveSpeakerLimits.spansPerUtterance + 1])
                if let evidence, let covered: Int64 = evidence["covered"], covered == upper - lower,
                   let invalid: Int = evidence["invalid"], invalid == 0,
                   let spanCount: Int = evidence["spanCount"], spanCount <= LiveSpeakerLimits.spansPerUtterance,
                   let count: Int = evidence["identityCount"], count == 1,
                   let speaker: String = evidence["speaker"] {
                    utterance.speakerId = speaker
                    utterance.revision += 1
                    utterance.updatedAt = Date()
                    utterance.originDeviceId = deviceID
                    try utterance.update(db)
                    try db.execute(sql: """
                        INSERT INTO speakerAnalysisAutomaticAssignment(utteranceId, speakerId, utteranceRevision) VALUES (?, ?, ?)
                        """, arguments: [utterance.id, speaker, utterance.revision])
                }
                try db.execute(sql: """
                    INSERT INTO liveSpeakerChecked(utteranceId, epoch, bindingRevision) VALUES (?, ?, ?)
                    ON CONFLICT(utteranceId) DO UPDATE SET epoch = excluded.epoch, bindingRevision = excluded.bindingRevision
                    """, arguments: [utterance.id, epoch, revision])
            }
            return rows.count == 128
        }
    }
}
