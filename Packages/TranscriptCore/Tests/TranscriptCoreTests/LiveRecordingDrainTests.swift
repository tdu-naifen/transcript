import Foundation
import Testing
@testable import TranscriptCore

@Suite struct LiveRecordingDrainTests {
    @Test func stopWaitsForPendingASRAndDelayedDiarizationBeforeReopen() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let utterances = UtteranceRepository(database)
        let speakers = SpeakerRepository(database)
        let meeting = makeTestMeeting(id: "drain-reopen")
        try await meetings.insert(meeting)

        let speaker = Speaker(id: "drain-speaker", anonymousName: "Heron", originDeviceId: testiPhoneId)
        try await speakers.upsert(speaker)
        let utterance = Utterance(
            id: "pending-final", meetingId: meeting.id, startMs: 120, endMs: 840,
            text: "Persisted after stop", originDeviceId: testiPhoneId
        )

        try await LiveRecordingDrain.wait(
            asr: {
                try await Task.sleep(for: .milliseconds(20))
                try await utterances.append(utterance)
            },
            diarization: {
                try await Task.sleep(for: .milliseconds(60))
                try await speakers.assignDisplayIndex(
                    meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0,
                    deviceId: testiPhoneId
                )
                try await utterances.assignSpeaker(
                    utteranceId: utterance.id, speakerId: speaker.id, deviceId: testiPhoneId
                )
            }
        )

        let reopenedUtterances = UtteranceRepository(database)
        let reopenedSpeakers = SpeakerRepository(database)
        let stored = try #require(try await reopenedUtterances.fetch(meetingId: meeting.id).first)
        #expect(stored.text == "Persisted after stop")
        #expect(stored.startMs == 120)
        #expect(stored.endMs == 840)
        #expect(stored.speakerId == speaker.id)
        #expect(try await reopenedSpeakers.speakers(inMeeting: meeting.id).map(\.speaker.id) == [speaker.id])
    }

    @Test func oneFailureDoesNotCancelTheOtherDrainBranch() async {
        let probe = DrainProbe()
        await #expect(throws: LiveRecordingDrainError.self) {
            try await LiveRecordingDrain.wait(
                asr: { throw DrainTestError.asrFailed },
                diarization: { await probe.markDiarizationFinished() }
            )
        }
        #expect(await probe.diarizationFinished)
    }
}

private enum DrainTestError: Error {
    case asrFailed
}

private actor DrainProbe {
    private(set) var diarizationFinished = false

    func markDiarizationFinished() {
        diarizationFinished = true
    }
}