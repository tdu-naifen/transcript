import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct ReprocessingVoiceprintTests {
    @Test func reliableMatchReusesIdentityWithoutSilentEnrollment() async throws {
        let database = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(database)
        let known = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(
            speakerId: known.id,
            floats: [1, 0],
            originDeviceId: testiPhoneId,
            modelIdentifier: "campplus-revision"
        ))
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "campplus-revision",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 1)
        )
        let result = embeddedResult([1, 0])

        let draft = try await MeetingReprocessor.speakerDraft(
            speakerIndex: 2,
            confirmedSpeakerId: nil,
            result: result,
            matcher: matcher
        )
        #expect(draft.existingSpeakerId == known.id)
        #expect(draft.wasVoiceprintMatch)

        let meeting = makeTestMeeting(id: "matched-reprocessing")
        try await MeetingRepository(database).insert(meeting)
        try await MeetingReprocessingRepository(database).replace(
            meetingId: meeting.id,
            utterances: [.init(startMs: 0, endMs: 1_000, text: "Matched", speakerIndex: 2)],
            speakers: [draft],
            deviceId: testiPhoneId
        )
        let embeddingCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM speakerEmbedding") ?? 0
        }
        #expect(embeddingCount == 1)
    }

    @Test func missingModelRevisionKeepsEmbeddingEvidenceButDisablesGlobalMatch() async throws {
        let result = embeddedResult([1, 0])

        let draft = try await MeetingReprocessor.speakerDraft(
            speakerIndex: 0,
            confirmedSpeakerId: nil,
            result: result,
            matcher: nil
        )

        #expect(draft.existingSpeakerId == nil)
        #expect(draft.embedding == [1, 0])
        #expect(!draft.wasVoiceprintMatch)
    }

    @Test func confirmedHistoricalIdentityWinsOverConflictingAutomaticMatch() async throws {
        let database = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(database)
        let historical = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let candidate = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(
            speakerId: candidate.id,
            floats: [1, 0],
            originDeviceId: testiPhoneId,
            modelIdentifier: "campplus-revision"
        ))
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "campplus-revision",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 1)
        )

        let draft = try await MeetingReprocessor.speakerDraft(
            speakerIndex: 0,
            confirmedSpeakerId: historical.id,
            result: embeddedResult([1, 0]),
            matcher: matcher
        )

        #expect(draft.existingSpeakerId == historical.id)
        #expect(!draft.wasVoiceprintMatch)
    }

    @Test func explicitCancellationCheckRollsBackReplacementAndPreservesOldData() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = makeTestMeeting(id: "cancelled-replacement", title: "Original title")
        try await MeetingRepository(database).insert(meeting)
        let oldSpeaker = Speaker(
            id: "old-speaker",
            displayName: "Confirmed name",
            anonymousName: "Otter",
            originDeviceId: testiPhoneId
        )
        let speakers = SpeakerRepository(database)
        try await speakers.upsert(oldSpeaker)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id,
            speakerId: oldSpeaker.id,
            displayIndex: 0,
            deviceId: testiPhoneId
        )
        let oldUtterance = Utterance(
            id: "old-utterance",
            meetingId: meeting.id,
            startMs: 0,
            endMs: 1_000,
            text: "Old text",
            speakerId: oldSpeaker.id,
            originDeviceId: testiPhoneId
        )
        try await UtteranceRepository(database).append(oldUtterance)

        await #expect(throws: CancellationError.self) {
            try await MeetingReprocessingRepository(database).replace(
                meetingId: meeting.id,
                utterances: [.init(startMs: 0, endMs: 500, text: "Late text", speakerIndex: 0)],
                speakers: [.init(speakerIndex: 0, existingSpeakerId: oldSpeaker.id)],
                deviceId: testiPhoneId,
                cancellationCheck: { throw CancellationError() }
            )
        }

        let storedMeeting = try #require(try await MeetingRepository(database).fetch(id: meeting.id))
        #expect(storedMeeting.title == meeting.title)
        #expect(storedMeeting.audioFileName == meeting.audioFileName)
        let stored = try #require(try await UtteranceRepository(database).fetch(meetingId: meeting.id).first)
        #expect(stored.id == oldUtterance.id)
        #expect(stored.text == oldUtterance.text)
        #expect(try await speakers.fetch(id: oldSpeaker.id)?.displayName == "Confirmed name")
    }

    private func embeddedResult(_ embedding: [Float]) -> VoiceprintProcessingResult {
        VoiceprintProcessingResult(
            meetingId: "meeting",
            speakerSlot: 0,
            generation: 1,
            outcome: .embedded(embedding),
            match: nil,
            evidence: .init(ranges: [0..<32_000], cleanFrameCount: 32_000, sampleRate: 16_000)
        )
    }
}
