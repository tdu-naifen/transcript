import Foundation

public struct VoiceprintCandidate: Sendable, Equatable {
    public let speakerId: String
    /// Raw cosine similarity, not a probability.
    public let score: Float

    public init(speakerId: String, score: Float) {
        self.speakerId = speakerId
        self.score = score
    }
}

public struct VoiceprintMatchEvidence: Sendable, Equatable {
    /// At most two candidates, each belonging to a different speaker.
    public let candidates: [VoiceprintCandidate]
    /// Database generation of the coherent snapshot used to make this decision.
    public let voiceprintGeneration: Int

    public init(candidates: [VoiceprintCandidate], voiceprintGeneration: Int) {
        self.candidates = candidates
        self.voiceprintGeneration = voiceprintGeneration
    }
}

public enum VoiceprintMatchResult: Sendable, Equatable {
    case matched(speakerId: String, evidence: VoiceprintMatchEvidence)
    case needsMoreAudio(candidates: [VoiceprintCandidate])
    case noMatch(candidates: [VoiceprintCandidate])
}

/// Uncalibrated policy knobs. Defaults are conservative starting values and must be
/// evaluated against representative same-speaker/different-speaker recordings.
public struct VoiceprintMatchPolicy: Sendable, Equatable {
    public var minimumSimilarity: Float
    public var minimumMargin: Float
    public var minimumCleanDuration: TimeInterval

    public init(
        minimumSimilarity: Float = 0.7,
        minimumMargin: Float = 0.1,
        minimumCleanDuration: TimeInterval = 2
    ) {
        self.minimumSimilarity = minimumSimilarity
        self.minimumMargin = minimumMargin
        self.minimumCleanDuration = minimumCleanDuration
    }
}

/// Exact O(N) matcher backed by a generation-invalidated, normalized in-memory snapshot.
/// Model identity is mandatory; legacy nil-model templates require explicit opt-in.
public actor VoiceprintMatcher {
    private let speakers: SpeakerRepository
    private let modelIdentifier: String
    private let policy: VoiceprintMatchPolicy
    private let includeLegacyEmbeddings: Bool
    private var snapshot: VoiceprintSnapshot?

    public init(
        speakers: SpeakerRepository,
        modelIdentifier: String,
        policy: VoiceprintMatchPolicy = .init(),
        includeLegacyEmbeddings: Bool = false
    ) {
        self.speakers = speakers
        self.modelIdentifier = modelIdentifier
        self.policy = policy
        self.includeLegacyEmbeddings = includeLegacyEmbeddings
    }

    public func match(
        embedding: [Float],
        cleanDuration: TimeInterval
    ) async throws -> VoiceprintMatchResult {
        guard let query = FloatVector.normalized(embedding), cleanDuration.isFinite,
              cleanDuration >= 0 else { return .noMatch(candidates: []) }
        let (ranked, generation) = try await rankedCandidates(for: query)
        guard cleanDuration >= policy.minimumCleanDuration else {
            return .needsMoreAudio(candidates: ranked)
        }
        guard let first = ranked.first, first.score >= policy.minimumSimilarity else {
            return .noMatch(candidates: ranked)
        }
        let margin = first.score - (ranked.dropFirst().first?.score ?? -1)
        guard margin >= policy.minimumMargin else { return .noMatch(candidates: ranked) }
        return .matched(
            speakerId: first.speakerId,
            evidence: VoiceprintMatchEvidence(
                candidates: ranked, voiceprintGeneration: generation
            )
        )
    }

    private func rankedCandidates(
        for query: [Float]
    ) async throws -> (candidates: [VoiceprintCandidate], generation: Int) {
        while true {
            let current = try await currentSnapshot()
            var bestBySpeaker: [String: Float] = [:]
            query.withUnsafeBufferPointer { queryBuffer in
                current.values.withUnsafeBufferPointer { valuesBuffer in
                    for entry in current.entries where entry.dimension == query.count {
                        let candidate = UnsafeBufferPointer(
                            rebasing: valuesBuffer[entry.offset..<(entry.offset + entry.dimension)]
                        )
                        let score = FloatVector.dot(queryBuffer, candidate)
                        guard score.isFinite else { continue }
                        if score > (bestBySpeaker[entry.speakerId] ?? -.infinity) {
                            bestBySpeaker[entry.speakerId] = score
                        }
                    }
                }
            }
            guard try await speakers.voiceprintGeneration() == current.generation else {
                snapshot = nil
                continue
            }
            var ranked = bestBySpeaker.map {
                VoiceprintCandidate(speakerId: $0.key, score: $0.value)
            }
            ranked.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.speakerId < $1.speakerId
            }
            return (Array(ranked.prefix(2)), current.generation)
        }
    }

    private func currentSnapshot() async throws -> VoiceprintSnapshot {
        let generation = try await speakers.voiceprintGeneration()
        if let snapshot, snapshot.generation == generation { return snapshot }
        let loaded = try await speakers.loadVoiceprintSnapshot(
            modelIdentifier: modelIdentifier, includeLegacy: includeLegacyEmbeddings
        )
        snapshot = loaded
        return loaded
    }
}
