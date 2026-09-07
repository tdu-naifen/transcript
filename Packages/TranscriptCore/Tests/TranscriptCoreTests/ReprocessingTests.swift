import Foundation
import FluidAudio
import Testing
@testable import TranscriptCore

@Suite struct ReprocessingTests {
    @Test func staleRetrySnapshotCannotReplaceConcurrentEditsOrChangedAudio() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(
            title: "Edited retry", startedAt: Date(), audioSHA256: "original-hash",
            state: .recorded, originDeviceId: "test"
        )
        try await MeetingRepository(database).insert(meeting)
        let utterance = Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 1000, text: "Original",
            localeIdentifier: "en-US", originDeviceId: "test"
        )
        let repository = UtteranceRepository(database)
        try await repository.append(utterance)
        let original = try await repository.fetch(meetingId: meeting.id)
        let snapshot = MeetingReprocessingSnapshot(audioSHA256: meeting.audioSHA256, utterances: original)
        let speaker = try await SpeakerRepository(database).createAnonymousSpeaker(deviceId: "test")
        try await repository.assignSpeaker(utteranceId: utterance.id, speakerId: speaker.id, deviceId: "test")
        let edited = try await repository.fetch(meetingId: meeting.id)
        await #expect(throws: MeetingReprocessingSnapshotError.self) {
            try await MeetingReprocessingRepository(database).replace(
                meetingId: meeting.id,
                utterances: [.init(startMs: 0, endMs: 1000, text: "Replacement")], speakers: [],
                deviceId: "test", expectedSnapshot: snapshot
            )
        }
        #expect(try await repository.fetch(meetingId: meeting.id) == edited)
        await #expect(throws: MeetingReprocessingSnapshotError.self) {
            try await MeetingReprocessingRepository(database).replace(
                meetingId: meeting.id,
                utterances: [.init(startMs: 0, endMs: 1000, text: "Replacement")], speakers: [],
                deviceId: "test",
                expectedSnapshot: .init(audioSHA256: "different-hash", utterances: edited)
            )
        }
        #expect(try await repository.fetch(meetingId: meeting.id) == edited)
    }

    private func segment(_ speakerIndex: Int, _ startFrame: Int, _ endFrame: Int) -> DiarizerSegment {
        DiarizerSegment(
            speakerIndex: speakerIndex, startFrame: startFrame, endFrame: endFrame,
            frameDurationSeconds: 1.0
        )
    }

    @Test func zeroTranscriptCanBeAtomicallyReprocessedWithoutChangingRecordingIdentity() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = MeetingReprocessingRepository(database)
        let meeting = Meeting(
            id: "zero-transcript",
            title: "Customer interview",
            startedAt: Date(timeIntervalSince1970: 1_788_552_600),
            durationMs: 42_000,
            audioFileName: "original.m4a",
            audioSHA256: "sealed-sha",
            audioByteCount: 8_192,
            state: .recorded,
            originDeviceId: testiPhoneId
        )
        try await meetings.insert(meeting)
        let known = Speaker(
            id: "known-speaker",
            displayName: "Alex",
            anonymousName: "Marmot",
            colorIndex: 3,
            originDeviceId: testiPhoneId
        )
        try await speakers.upsert(known)

        let result = try await repository.replace(
            meetingId: meeting.id,
            utterances: [ReprocessedUtteranceDraft(
                startMs: 200,
                endMs: 1_800,
                text: "Hello from the saved recording.",
                speakerIndex: 0,
                localeIdentifier: "en-US"
            )],
            speakers: [ReprocessedSpeakerDraft(
                speakerIndex: 0,
                existingSpeakerId: known.id,
                embedding: [1, 0, 0]
            )],
            deviceId: testiPhoneId
        )

        let storedMeeting = try #require(try await meetings.fetch(id: meeting.id))
        #expect(storedMeeting.id == meeting.id)
        #expect(storedMeeting.title == meeting.title)
        #expect(storedMeeting.startedAt == meeting.startedAt)
        #expect(storedMeeting.durationMs == meeting.durationMs)
        #expect(storedMeeting.audioFileName == meeting.audioFileName)
        #expect(storedMeeting.audioSHA256 == meeting.audioSHA256)
        #expect(storedMeeting.audioByteCount == meeting.audioByteCount)
        #expect(storedMeeting.localeIdentifier == "en-US")
        #expect(try await speakers.fetch(id: known.id)?.displayName == "Alex")
        #expect(try await speakers.speakers(inMeeting: meeting.id).map(\.speaker.id) == [known.id])
        #expect(try await utterances.fetch(meetingId: meeting.id).map(\.text) == [
            "Hello from the saved recording."
        ])
        #expect(result.utteranceCount == 1)
        #expect(result.speakerCount == 1)
    }

    @Test func failedReplacementRollsBackOldTranscriptAndSpeakerLinks() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = MeetingReprocessingRepository(database)
        let meeting = makeTestMeeting(id: "rollback-meeting", title: "Keep me")
        try await meetings.insert(meeting)
        let oldSpeaker = Speaker(
            id: "old-speaker",
            displayName: "Confirmed name",
            anonymousName: "Otter",
            originDeviceId: testiPhoneId
        )
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
            text: "Original transcript",
            speakerId: oldSpeaker.id,
            originDeviceId: testiPhoneId
        )
        try await utterances.append(oldUtterance)

        await #expect(throws: (any Error).self) {
            try await repository.replace(
                meetingId: meeting.id,
                utterances: [ReprocessedUtteranceDraft(
                    startMs: 0,
                    endMs: 500,
                    text: "Partial new transcript",
                    speakerIndex: 0
                )],
                speakers: [ReprocessedSpeakerDraft(
                    speakerIndex: 0,
                    existingSpeakerId: "missing-speaker"
                )],
                deviceId: testiPhoneId
            )
        }

        #expect(try await meetings.fetch(id: meeting.id)?.title == "Keep me")
        let restored = try #require(try await utterances.fetch(meetingId: meeting.id).first)
        #expect(restored.id == oldUtterance.id)
        #expect(restored.text == oldUtterance.text)
        #expect(restored.speakerId == oldSpeaker.id)
        #expect(try await speakers.speakers(inMeeting: meeting.id).map(\.speaker.id) == [oldSpeaker.id])
        #expect(try await speakers.fetch(id: oldSpeaker.id)?.displayName == "Confirmed name")
    }

    @Test func voiceprintSamplesExcludeOverlappingSpeech() {
        let samples = (0..<(4 * 16_000)).map(Float.init)
        let clean = MeetingReprocessor.samples(
            forSpeakerIndex: 0,
            from: samples,
            segments: [segment(0, 0, 4), segment(1, 1, 3)]
        )

        #expect(clean.count == 2 * 16_000)
        #expect(clean.first == 0)
        #expect(clean[16_000] == Float(3 * 16_000))
        #expect(clean.last == Float(4 * 16_000 - 1))
    }
}