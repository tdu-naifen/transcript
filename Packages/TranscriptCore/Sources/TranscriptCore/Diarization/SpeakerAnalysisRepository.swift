import Foundation
import GRDB

public struct DetectedVoiceprint: Sendable {
    public let slot: Int
    public let embedding: [Float]?
    public let cleanDuration: TimeInterval

    public init(slot: Int, embedding: [Float]?, cleanDuration: TimeInterval) {
        self.slot = slot
        self.embedding = embedding
        self.cleanDuration = cleanDuration
    }
}

/// Local automatic enrollment is an explicit product policy, not sync authorization.
public struct SpeakerAnalysisRepository: Sendable {
    private let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func enqueue(meetingID: String, retry: Bool = false) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO speakerAnalysisJob(meetingId, state, updatedAt) VALUES (?, 'pending', ?)
                ON CONFLICT(meetingId) DO NOTHING
                """, arguments: [meetingID, Date()])
            if retry {
                try db.execute(sql: "UPDATE speakerAnalysisJob SET state = CASE WHEN state IN ('running', 'rerun') THEN 'rerun' ELSE 'pending' END, error = NULL, updatedAt = ? WHERE meetingId = ?",
                               arguments: [Date(), meetingID])
            }
        }
    }

    public func nextPending() async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT meetingId FROM speakerAnalysisJob WHERE state IN ('pending', 'running', 'rerun') ORDER BY updatedAt, meetingId LIMIT 1")
        }
    }

    public func setState(meetingID: String, state: String, error: String? = nil) async throws {
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE speakerAnalysisJob
                SET state = CASE WHEN state = 'rerun' AND ? != 'running' THEN 'pending' ELSE ? END,
                    error = CASE WHEN state = 'rerun' THEN NULL ELSE ? END, updatedAt = ?
                WHERE meetingId = ?
                """, arguments: [state, state, error, Date(), meetingID])
        }
    }

    public func failure(meetingID: String) async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT error FROM speakerAnalysisJob WHERE meetingId = ? AND state = 'failed'", arguments: [meetingID])
        }

    }

    public func state(meetingID: String) async throws -> String? {
        try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM speakerAnalysisJob WHERE meetingId = ?", arguments: [meetingID])
        }
    }

    /// Changes only identity associations; text, timestamps, audio and user names are untouched.
    @discardableResult
    public func apply(
        meetingID: String,
        expectedUtterances: [Utterance],
        slotsByUtterance: [String: Int],
        voices: [DetectedVoiceprint],
        modelIdentifier: String,
        deviceID: String,
        policy: VoiceprintMatchPolicy = .init()
    ) async throws -> [Int: Speaker] {
        guard !modelIdentifier.isEmpty else { throw VoiceprintBindingError.invalidEmbedding }
        return try await database.writer.write { db in
            try Task.checkCancellation()
            guard try Meeting.exists(db, key: meetingID) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: meetingID)
            }
            let current = try Utterance.filter(Utterance.Columns.meetingId == meetingID).fetchAll(db)
            guard current.sorted(by: { $0.id < $1.id }) == expectedUtterances.sorted(by: { $0.id < $1.id }) else {
                throw VoiceprintBindingError.staleExpectation
            }
            let links = try MeetingSpeaker.filter(Column("meetingId") == meetingID).fetchAll(db)
            let oldBySlot = Dictionary(uniqueKeysWithValues: links.map { ($0.displayIndex, $0.speakerId) })
            var bank = try SpeakerEmbedding.filter(SpeakerEmbedding.Columns.modelIdentifier == modelIdentifier).fetchAll(db)
            var resolved: [Int: Speaker] = [:]
            var usedNames = Set(try String.fetchAll(db, sql: "SELECT anonymousName FROM speaker"))
            for voice in voices.sorted(by: { $0.slot < $1.slot }) {
                guard voice.slot >= 0, resolved[voice.slot] == nil else { throw VoiceprintBindingError.staleExpectation }
                guard voice.cleanDuration.isFinite, voice.cleanDuration >= 0 else { throw VoiceprintBindingError.invalidEmbedding }
                let vector = voice.embedding.flatMap(FloatVector.normalized)
                if voice.embedding != nil, vector == nil { throw VoiceprintBindingError.invalidEmbedding }
                var chosen: String?
                let previous = try oldBySlot[voice.slot].flatMap { try Speaker.fetchOne(db, key: $0) }
                let previouslyNamed = try Set(current.filter { slotsByUtterance[$0.id] == voice.slot }.compactMap(\.speakerId))
                    .compactMap { try Speaker.fetchOne(db, key: $0) }
                    .filter { $0.displayName != nil }
                if previouslyNamed.count > 1 { continue }
                if previouslyNamed.count == 1 { chosen = previouslyNamed.first?.id }
                if chosen == nil, let vector {
                    var scores: [String: Float] = [:]
                    for template in bank where template.dimension == vector.count {
                        guard let candidate = FloatVector.normalized(template.floats),
                              candidate.count == vector.count else { continue }
                        let score = zip(vector, candidate).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                        scores[template.speakerId] = max(scores[template.speakerId] ?? -.infinity, score)
                    }
                    var candidates: [VoiceprintCandidate] = scores.map { entry in
                        VoiceprintCandidate(speakerId: entry.key, score: entry.value)
                    }
                    candidates.sort { first, second in
                        if first.score == second.score { return first.speakerId < second.speakerId }
                        return first.score > second.score
                    }
                    if case .matched(let id, _) = policy.evaluate(candidates: Array(candidates.prefix(2)), cleanDuration: voice.cleanDuration, generation: 0) {
                        chosen = id
                    }
                }
                let speaker: Speaker
                let reusablePrevious = previous.flatMap { old in
                    vector == nil || !bank.contains(where: { $0.speakerId == old.id }) ? old.id : nil
                }
                if let id = chosen ?? reusablePrevious, let existing = try Speaker.fetchOne(db, key: id) {
                    speaker = existing
                } else {
                    let name = AnonymousNameGenerator.nextName(usedNames: Array(usedNames))
                    usedNames.insert(name)
                    speaker = Speaker(anonymousName: name, colorIndex: try Speaker.fetchCount(db) % 12, originDeviceId: deviceID)
                    try speaker.insert(db)
                }
                resolved[voice.slot] = speaker
                if let vector, voice.cleanDuration >= policy.minimumCleanDuration,
                   !bank.contains(where: { $0.speakerId == speaker.id }) {
                    let template = SpeakerEmbedding(speakerId: speaker.id, floats: vector, originDeviceId: deviceID, modelIdentifier: modelIdentifier)
                    try template.insert(db)
                    bank.append(template)
                }
            }
            try db.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId = ?", arguments: [meetingID])
            var linked: Set<String> = []
            for slot in resolved.keys.sorted() {
                guard let speaker = resolved[slot], linked.insert(speaker.id).inserted else { continue }
                try MeetingSpeaker(meetingId: meetingID, speakerId: speaker.id, displayIndex: slot, originDeviceId: deviceID).insert(db)
            }
            for var utterance in current {
                if let id = utterance.speakerId,
                   try Speaker.fetchOne(db, key: id)?.displayName != nil { continue }
                let identity = slotsByUtterance[utterance.id].flatMap { resolved[$0]?.id }
                if let identity, identity != utterance.speakerId {
                    utterance.speakerId = identity
                    utterance.revision += 1
                    utterance.updatedAt = Date()
                    utterance.originDeviceId = deviceID
                    try utterance.update(db)
                }
            }
            let retainedIDs = Set(try Utterance.filter(Utterance.Columns.meetingId == meetingID).fetchAll(db).compactMap(\.speakerId))
            var nextIndex = (resolved.keys.max() ?? -1) + 1
            for id in retainedIDs.sorted() where linked.insert(id).inserted {
                try MeetingSpeaker(meetingId: meetingID, speakerId: id, displayIndex: nextIndex, originDeviceId: deviceID).insert(db)
                nextIndex += 1
            }
            try Task.checkCancellation()
            try db.execute(sql: "UPDATE speakerAnalysisJob SET state = CASE WHEN state = 'rerun' THEN 'pending' ELSE 'complete' END, error = NULL, updatedAt = ? WHERE meetingId = ?",
                           arguments: [Date(), meetingID])
            return resolved
        }
    }
}
