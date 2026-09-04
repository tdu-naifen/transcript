import FluidAudio
import Foundation
import Testing

@testable import TranscriptCore

/// PLAN work item 3: FluidAudio has no built-in ASR⊕diarization join. None of this needs
/// the Sortformer model — it is pure interval maths over synthetic timings.
@Suite struct SpeakerOverlapAssignerTests {
    // A 1-second frame duration keeps `startTime`/`endTime` exactly equal to the given
    // frame indices — the `startTime:`/`endTime:` initializer instead round-trips through
    // `Int(round(seconds / frameDurationSeconds))`, which is lossy at 0.08s granularity
    // and made otherwise-exact ties flaky.
    private func segment(_ speakerIndex: Int, _ startFrame: Int, _ endFrame: Int) -> DiarizerSegment {
        DiarizerSegment(
            speakerIndex: speakerIndex, startFrame: startFrame, endFrame: endFrame,
            frameDurationSeconds: 1.0
        )
    }

    @Test func exactOverlapPicksTheMatchingSpeaker() {
        let segments = [segment(0, 0, 1)]
        let index = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: 0, utteranceEndMs: 1000, segments: segments
        )
        #expect(index == 0)
    }

    @Test func partialOverlapStillWinsOverNoOverlap() {
        let segments = [segment(0, 0, 1), segment(1, 5, 6)]
        let index = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: 500, utteranceEndMs: 1500, segments: segments
        )
        #expect(index == 0)
    }

    @Test func noOverlapReturnsNil() {
        let segments = [segment(0, 5, 6)]
        let index = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: 0, utteranceEndMs: 1000, segments: segments
        )
        #expect(index == nil)
    }

    @Test func utteranceSpanningTwoSpeakersPicksTheLargerOverlap() {
        // Utterance [0, 3000)ms; speaker 0 covers [0,2)s (2s overlap), speaker 1
        // covers [2,3)s (1s overlap) — speaker 0 wins.
        let segments = [segment(0, 0, 2), segment(1, 2, 3)]
        let index = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: 0, utteranceEndMs: 3000, segments: segments
        )
        #expect(index == 0)
    }

    @Test func tiesRemainUnassignedRegardlessOfOrder() {
        let segments = [segment(2, 0, 1), segment(0, 1, 2)]
        let index = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: 0, utteranceEndMs: 2000, segments: segments
        )
        #expect(index == nil)

        let reordered = [segment(0, 1, 2), segment(2, 0, 1)]
        let reorderedIndex = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: 0, utteranceEndMs: 2000, segments: reordered
        )
        #expect(reorderedIndex == nil)
    }

    @Test func adjacentSegmentsForTheSameSpeakerAccumulateBeforeComparison() {
        let segments = [segment(1, 0, 1), segment(1, 1, 2), segment(0, 2, 3)]
        let index = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: 0, utteranceEndMs: 3000, segments: segments
        )
        #expect(index == 1)
    }
}

@Suite struct DiarizationTimelineAccumulatorTests {
    private func segment(_ speakerIndex: Int, _ startFrame: Int, _ endFrame: Int) -> DiarizerSegment {
        DiarizerSegment(
            speakerIndex: speakerIndex, startFrame: startFrame, endFrame: endFrame,
            frameDurationSeconds: 1.0
        )
    }

    @Test func finalizedDeltasAccumulateAndTentativeTailIsReplaced() {
        var timeline = DiarizationTimelineAccumulator()
        let firstFinal = segment(0, 0, 1)
        let firstTentative = segment(1, 1, 2)
        timeline.apply(finalized: [firstFinal], tentative: [firstTentative])

        let secondFinal = segment(1, 1, 2)
        let replacementTentative = segment(0, 2, 3)
        timeline.apply(finalized: [secondFinal], tentative: [replacementTentative])

        #expect(timeline.finalized.map(\.speakerIndex) == [0, 1])
        #expect(timeline.tentative.map(\.speakerIndex) == [0])
        #expect(timeline.segments.count == 3)
    }

    @Test func emptyFinalizedDeltaDoesNotEraseStableHistory() {
        var timeline = DiarizationTimelineAccumulator()
        timeline.apply(finalized: [segment(2, 0, 1)], tentative: [segment(3, 1, 2)])
        timeline.apply(finalized: [], tentative: [segment(3, 1, 3)])

        #expect(timeline.finalized.map(\.speakerIndex) == [2])
        #expect(timeline.tentative.map(\.speakerIndex) == [3])
        #expect(timeline.tentative.first?.endTime == 3)
    }
}

/// PLAN work item 4: CAM++ produces the embedding, our GRDB tables stay authoritative.
/// None of this needs the CAM++ model — embeddings are supplied directly.
@Suite struct VoiceprintBinderTests {
    private func vector192(seed: Float) -> [Float] {
        var values = [Float](repeating: 0, count: 192)
        values[0] = 1
        values[1] = seed
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return values.map { $0 / norm }
    }

    @Test func aboveThresholdReusesTheExistingSpeakerId() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let binder = VoiceprintBinder(speakers: speakers)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let existing = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: existing.id, floats: vector192(seed: 0)))

        let binding = try await binder.bind(
            embedding: vector192(seed: 0.001),
            meetingId: meeting.id,
            speakerIndex: 0,
            deviceId: testiPhoneId,
            threshold: 0.9
        )

        #expect(binding.isNewSpeaker == false)
        #expect(binding.speakerId == existing.id)
        let listed = try await speakers.speakers(inMeeting: meeting.id)
        #expect(listed.map(\.speaker.id) == [existing.id])
        #expect(listed.map(\.displayIndex) == [0])
    }

    @Test func belowThresholdCreatesANewSpeakerWithAnUnusedName() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let binder = VoiceprintBinder(speakers: speakers)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let existing = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: existing.id, floats: vector192(seed: 0)))

        // Orthogonal to the seeded vector's first two dimensions.
        var orthogonal = [Float](repeating: 0, count: 192)
        orthogonal[2] = 1
        let binding = try await binder.bind(
            embedding: orthogonal,
            meetingId: meeting.id,
            speakerIndex: 1,
            deviceId: testiPhoneId,
            threshold: 0.9
        )

        #expect(binding.isNewSpeaker == true)
        #expect(binding.speakerId != existing.id)
        let created = try #require(try await speakers.fetch(id: binding.speakerId))
        #expect(created.anonymousName != existing.anonymousName)

        // `existing` was seeded with an embedding only, never linked to this meeting, so
        // it must not appear here — only the slot that was just bound should.
        let listed = try await speakers.speakers(inMeeting: meeting.id)
        #expect(listed.map(\.speaker.id) == [binding.speakerId])
        #expect(listed.map(\.displayIndex) == [1])
    }

    @Test func bindingStoresA192DimensionalEmbedding() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let binder = VoiceprintBinder(speakers: speakers)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let vector = vector192(seed: 0.5)
        let binding = try await binder.bind(
            embedding: vector, meetingId: meeting.id, speakerIndex: 0, deviceId: testiPhoneId
        )

        let stored = try #require(try await speakers.embeddings(forSpeaker: binding.speakerId).first)
        #expect(stored.dimension == 192)
        #expect(stored.floats == vector)
    }
}

/// `CampPlusEmbedder.cosine` is a `nonisolated static` pure function — no model load
/// needed, so this exercises it directly without the CAM++ model being present.
@Suite struct CampPlusCosineTests {
    @Test func identicalEmbeddingsAreCloseToOne() {
        // `cosine` is a plain dot product — CAM++'s contract is that `embed(audio:)`
        // already L2-normalizes, so callers (including this test) must pass unit vectors.
        let raw: [Float] = (0..<192).map { Float($0) * 0.01 + 1 }
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        let v = raw.map { $0 / norm }
        #expect(abs(CampPlusEmbedder.cosine(v, v) - 1.0) < 1e-4)
    }

    @Test func orthogonalEmbeddingsAreCloseToZero() {
        var a = [Float](repeating: 0, count: 192)
        var b = [Float](repeating: 0, count: 192)
        a[0] = 1
        b[1] = 1
        #expect(abs(CampPlusEmbedder.cosine(a, b)) < 1e-6)
    }
}
