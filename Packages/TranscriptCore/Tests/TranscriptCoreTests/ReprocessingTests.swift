import Foundation
import CoreMedia
import FluidAudio
import Testing
@testable import TranscriptCore

@Suite struct ReprocessingTests {
    @Test func invalidReplacementTimingPreservesPublishedRowsAndMetadata() async throws {
        for engine in [TranscriptionEngine.appleSpeech, .nemotron] {
            for (start, end) in [(0, 1050), (-1, 900), (900, 899)] {
                let database = try AppDatabase.inMemory()
                let meeting = Meeting(title: "Keep original", startedAt: Date(), durationMs: 1000,
                    audioFileName: "original.m4a", audioSHA256: "original-hash", audioByteCount: 4000,
                    state: .recorded, originDeviceId: "test")
                try await MeetingRepository(database).insert(meeting)
                let speaker = try await SpeakerRepository(database).createAnonymousSpeaker(deviceId: "test")
                try await SpeakerRepository(database).assignDisplayIndex(
                    meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: "test"
                )
                try await UtteranceRepository(database).append(Utterance(
                    meetingId: meeting.id, startMs: 0, endMs: 900, text: "Preserved user edit",
                    speakerId: speaker.id, revision: 4, originDeviceId: "test"
                ))
                let original = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
                let originalMeeting = try await MeetingRepository(database).fetch(id: meeting.id)
                let originalLinks = try await database.reader.read { try MeetingSpeaker.fetchAll($0) }
                let originalSpeakers = try await database.reader.read { try Speaker.fetchAll($0) }
                if end == 1050 {
                    // Synthetic decoded input is longer than the persisted capture duration.
                    let range = CMTimeRange(start: .zero, duration: CMTime(value: 1050, timescale: 1000))
                    let acceptedByInput = try TranscriptAudioTimeline.bounds(for: range, finalInputEndMs: 1100)
                    #expect(acceptedByInput.endMs == 1050)
                }
                await #expect(throws: MeetingReprocessingTimingError.self) {
                    try await MeetingReprocessingRepository(database).replace(
                        meetingId: meeting.id,
                        utterances: [.init(startMs: start, endMs: end, text: "Invalid replacement", speakerIndex: 0)],
                        speakers: [.init(speakerIndex: 0)], deviceId: "retry", engine: engine,
                        expectedSnapshot: .init(audioSHA256: meeting.audioSHA256, utterances: original)
                    )
                }
                #expect(try await UtteranceRepository(database).fetch(meetingId: meeting.id) == original)
                #expect(try await MeetingRepository(database).fetch(id: meeting.id) == originalMeeting)
                #expect(try await database.reader.read { try MeetingSpeaker.fetchAll($0) } == originalLinks)
                #expect(try await database.reader.read { try Speaker.fetchAll($0) } == originalSpeakers)
            }
        }
    }

    @Test func explicitValidReplacementCanReplaceLegacyOverrunAtExactSavedBoundary() async throws {
        for engine in [TranscriptionEngine.appleSpeech, .nemotron] {
            let database = try AppDatabase.inMemory()
            let meeting = Meeting(title: "Legacy timing", startedAt: Date(), durationMs: 1000,
                                  state: .recorded, originDeviceId: "test")
            try await MeetingRepository(database).insert(meeting)
            try await UtteranceRepository(database).append(Utterance(
                meetingId: meeting.id, startMs: 0, endMs: 1200, text: "Legacy overrun", originDeviceId: "test"
            ))
            let original = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
            let repository = MeetingReprocessingRepository(database)
            await #expect(throws: MeetingReprocessingTimingError.self) {
                try await repository.replace(meetingId: meeting.id,
                    utterances: [.init(startMs: 0, endMs: 1050, text: "Still outside")],
                    speakers: [], deviceId: "test", engine: engine)
            }
            #expect(try await UtteranceRepository(database).fetch(meetingId: meeting.id) == original)
            _ = try await repository.replace(meetingId: meeting.id,
                utterances: [.init(startMs: 0, endMs: 1000, text: "Valid explicit replacement")],
                speakers: [], deviceId: "test", engine: engine)
            let replacement = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
            #expect(replacement.map(\.endMs) == [1000])
            #expect(replacement.map(\.engine) == [engine])
            #expect(try await MeetingRepository(database).fetch(id: meeting.id)?.durationMs == 1000)
        }
    }

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
        var meeting = makeTestMeeting(id: "rollback-meeting", title: "Keep me")
        meeting.durationMs = 1000
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

        await #expect(throws: RepositoryError.notFound(table: Speaker.databaseTableName, id: "missing-speaker")) {
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