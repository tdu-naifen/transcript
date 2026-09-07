import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct VoiceprintCandidateTests {
    @Test func matchesTopSpeakerAndReturnsDistinctRunnerUp() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let first = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let second = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: first.id, floats: [1, 0], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1", preprocessing: VoiceprintPreprocessing.campPlus))
        try await speakers.addEmbedding(.init(speakerId: first.id, floats: [0.99, 0.01], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1", preprocessing: VoiceprintPreprocessing.campPlus))
        try await speakers.addEmbedding(.init(speakerId: second.id, floats: [0.8, 0.6], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1", preprocessing: VoiceprintPreprocessing.campPlus))

        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "cam++-v1",
            policy: .init(minimumSimilarity: 0.75, minimumMargin: 0.1, minimumCleanDuration: 1)
        )
        let result = try await matcher.match(embedding: [1, 0], cleanDuration: 2)

        guard case let .matched(speakerId, evidence) = result else {
            Issue.record("Expected automatic match, got \(result)")
            return
        }
        #expect(speakerId == first.id)
        let generation = try await speakers.voiceprintGeneration()
        #expect(evidence.voiceprintGeneration == generation)
        #expect(evidence.candidates.map(\.speakerId) == [first.id, second.id])
        #expect(evidence.candidates[0].score > evidence.candidates[1].score)
    }

    @Test func insufficientAudioReturnsCandidatesWithoutMatching() async throws {
        let (speakers, speaker) = try await repositoryWithEmbedding(modelIdentifier: "cam++-v1")
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "cam++-v1",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 3)
        )

        let result = try await matcher.match(embedding: [1, 0], cleanDuration: 2)
        guard case let .needsMoreAudio(candidates) = result else {
            Issue.record("Expected needsMoreAudio, got \(result)")
            return
        }
        #expect(candidates.map(\.speakerId) == [speaker.id])
    }

    @Test func ambiguousTopTwoDoesNotMatch() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let first = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let second = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: first.id, floats: [1, 0], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1", preprocessing: VoiceprintPreprocessing.campPlus))
        try await speakers.addEmbedding(.init(speakerId: second.id, floats: [0.999, 0.001], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1", preprocessing: VoiceprintPreprocessing.campPlus))
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "cam++-v1",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0.05, minimumCleanDuration: 0)
        )

        let result = try await matcher.match(embedding: [1, 0], cleanDuration: 1)
        guard case let .noMatch(candidates) = result else {
            Issue.record("Expected noMatch for ambiguous candidates, got \(result)")
            return
        }
        #expect(candidates.count == 2)
    }

    @Test func excludesLegacyAndOtherModelsByDefault() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let legacy = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let other = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: legacy.id, floats: [1, 0]))
        try await speakers.addEmbedding(.init(speakerId: other.id, floats: [1, 0], originDeviceId: testiPhoneId, modelIdentifier: "other"))

        let matcher = VoiceprintMatcher(speakers: speakers, modelIdentifier: "cam++-v1")
        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 10) == .noMatch(candidates: []))
    }

    @Test func legacyUnknownProvenanceRemainsQuarantinedEvenWithOldOptIn() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let legacy = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: legacy.id, floats: [1, 0]))

        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "cam++-v1",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 0),
            includeLegacyEmbeddings: true
        )
        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 1) == .noMatch(candidates: []))
    }

    @Test func invalidStoredAndQueryVectorsNeverParticipate() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let invalid = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: invalid.id, floats: [.nan, 1], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1"))
        let matcher = VoiceprintMatcher(speakers: speakers, modelIdentifier: "cam++-v1")

        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 10) == .noMatch(candidates: []))
        #expect(try await matcher.match(embedding: [.infinity, 0], cleanDuration: 10) == .noMatch(candidates: []))
        #expect(try await matcher.match(embedding: [0, 0], cleanDuration: 10) == .noMatch(candidates: []))
    }

    @Test func candidateLookupDoesNotWriteOrChangeGeneration() async throws {
        let (speakers, _) = try await repositoryWithEmbedding(modelIdentifier: "cam++-v1")
        let before = try await speakers.voiceprintGeneration()
        let matcher = VoiceprintMatcher(speakers: speakers, modelIdentifier: "cam++-v1")

        _ = try await matcher.match(embedding: [1, 0], cleanDuration: 10)
        _ = try await matcher.match(embedding: [1, 0], cleanDuration: 10)

        #expect(try await speakers.voiceprintGeneration() == before)
    }

    @Test func generationInvalidatesSnapshotAfterDeleteAndMerge() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let keep = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let absorb = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: absorb.id, floats: [1, 0], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1", preprocessing: VoiceprintPreprocessing.campPlus))
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "cam++-v1",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 0)
        )
        guard case .matched(absorb.id, _) = try await matcher.match(embedding: [1, 0], cleanDuration: 1) else {
            Issue.record("Expected initial match")
            return
        }

        try await speakers.mergeSpeakers(keep: keep.id, absorb: absorb.id, deviceId: testiPhoneId)
        guard case .matched(keep.id, _) = try await matcher.match(embedding: [1, 0], cleanDuration: 1) else {
            Issue.record("Expected merged identity after generation refresh")
            return
        }

        try await speakers.deleteEmbeddings(forSpeaker: keep.id, modelIdentifier: "cam++-v1")
        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 1) == .noMatch(candidates: []))
    }

    private func repositoryWithEmbedding(modelIdentifier: String) async throws -> (SpeakerRepository, Speaker) {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: speaker.id, floats: [1, 0], originDeviceId: testiPhoneId, modelIdentifier: modelIdentifier, preprocessing: VoiceprintPreprocessing.campPlus))
        return (speakers, speaker)
    }
}

@Suite struct SpeakerPrefixSearchTests {
    @Test func searchesEitherNameWithStableBoundedCursor() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        for (id, display, anonymous) in [
            ("a", "Alice", "Otter"),
            ("b", nil, "Alpaca"),
            ("c", "ALINA", "Bear"),
            ("d", "Bob", "Albatross")
        ] {
            try await speakers.upsert(Speaker(
                id: id, displayName: display, anonymousName: anonymous,
                originDeviceId: testiPhoneId
            ))
        }

        let first = try await speakers.searchNames(prefix: "al", limit: 2)
        #expect(first.speakers.map(\.id) == ["a", "b"])
        let cursor = try #require(first.nextCursor)
        let second = try await speakers.searchNames(prefix: "al", limit: 2, cursor: cursor)
        #expect(second.speakers.map(\.id) == ["c", "d"])
        #expect(second.nextCursor == nil)
    }

    @Test func clampsNameSearchLimit() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        for index in 0..<60 {
            try await speakers.upsert(Speaker(
                id: String(format: "%02d", index), anonymousName: "Alpaca \(index)",
                originDeviceId: testiPhoneId
            ))
        }
        #expect(try await speakers.searchNames(prefix: "Al", limit: 500).speakers.count == 50)
    }
}
