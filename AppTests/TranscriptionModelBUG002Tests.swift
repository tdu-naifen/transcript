import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class TranscriptionModelBUG002Tests: XCTestCase {
    func testFinishAcceptsUnknownOnlyTranscript() async throws {
        let (services, meeting) = try await makeFixture()
        try await UtteranceRepository(services.database).append(
            Utterance(
                meetingId: meeting.id, startMs: 100, endMs: 900,
                text: "Unknown text", speakerId: nil, originDeviceId: "test-device"
            )
        )
        let model = TranscriptionModel(
            services: services, meetingId: meeting.id,
            asrFinish: {}, diarizationFinish: {}
        )

        try await model.finish()

        XCTAssertEqual(model.status, .idle)
        let stored = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertNil(stored.first?.speakerId)
        XCTAssertEqual(stored.first?.text, "Unknown text")
    }

    func testFinishAcceptsMixedKnownAndUnknownSpeakers() async throws {
        let (services, meeting) = try await makeFixture()
        try await SpeakerRepository(services.database).upsert(
            Speaker(id: "speaker-1", anonymousName: "Heron", originDeviceId: "test-device")
        )
        let utterances = UtteranceRepository(services.database)
        try await utterances.append([
            Utterance(
                meetingId: meeting.id, startMs: 100, endMs: 900,
                text: "Unknown text", speakerId: nil, originDeviceId: "test-device"
            ),
            Utterance(
                meetingId: meeting.id, startMs: 900, endMs: 1_500,
                text: "Named text", speakerId: "speaker-1", originDeviceId: "test-device"
            )
        ])
        let model = TranscriptionModel(
            services: services, meetingId: meeting.id,
            asrFinish: {}, diarizationFinish: {}
        )

        try await model.finish()

        XCTAssertEqual(model.status, .idle)
        let stored = try await utterances.fetch(meetingId: meeting.id)
        XCTAssertEqual(stored.map(\.speakerId), [nil, "speaker-1"])
    }

    func testFinishPreservesNoTranscriptProduced() async throws {
        let (services, meeting) = try await makeFixture()
        let model = TranscriptionModel(
            services: services, meetingId: meeting.id,
            asrFinish: {}, diarizationFinish: {}
        )

        do {
            try await model.finish()
            XCTFail("finish should reject an empty transcript")
        } catch TranscriptionModel.RecordingError.noTranscriptProduced {
            XCTAssertEqual(model.status, .failed(RecordingLanguageText.speechFailure))
        }
    }

    func testFinishPropagatesFinalizationReadFailure() async throws {
        let (services, meeting) = try await makeFixture()
        try await services.database.writer.write { database in
            try database.execute(sql: "DROP TABLE utterance")
        }
        let model = TranscriptionModel(
            services: services, meetingId: meeting.id,
            asrFinish: {}, diarizationFinish: {}
        )

        do {
            try await model.finish()
            XCTFail("finish should propagate finalization read failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("utterance"))
            XCTAssertEqual(model.status, .failed(RecordingLanguageText.speechFailure))
        }
    }

    func testFinishPropagatesASRStorageFailureAndDrainsDiarization() async throws {
        let (services, meeting) = try await makeFixture()
        var original = Utterance(
            id: "duplicate-utterance", meetingId: meeting.id, startMs: 100, endMs: 900,
            text: "Persisted before drain failure", originDeviceId: "test-device"
        )
        original.localeIdentifier = "en-US"
        let duplicate = original
        try await UtteranceRepository(services.database).append(original)
        let diarizationProbe = DrainProbe()
        let database = services.database
        let model = TranscriptionModel(
            services: services,
            meetingId: meeting.id,
            asrFinish: {
                try await UtteranceRepository(database).append(duplicate)
            },
            diarizationFinish: {
                await diarizationProbe.markFinished()
            }
        )

        do {
            try await model.finish()
            XCTFail("finish should propagate the storage failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("UNIQUE"))
            XCTAssertEqual(model.status, .failed(RecordingLanguageText.speechFailure))
        }
        let diarizationFinished = await diarizationProbe.finished
        XCTAssertTrue(diarizationFinished)
        let stored = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(stored.first?.text, "Persisted before drain failure")
        XCTAssertEqual(stored.first?.startMs, 100)
        XCTAssertEqual(stored.first?.endMs, 900)
        XCTAssertEqual(stored.first?.localeIdentifier, "en-US")
        XCTAssertEqual(stored.first?.speakerId, nil)
        let storedMeeting = try await MeetingRepository(services.database).fetch(id: meeting.id)
        XCTAssertEqual(storedMeeting?.audioFileName, "recording.m4a")
        do {
            try await model.finish()
            XCTFail("A finished model must not finish a second time")
        } catch TranscriptionModel.RecordingError.processingNotRunning {
            XCTAssertTrue(true)
        }
    }

    func testOptionalDiarizationFailureDoesNotFailValidTranscriptOrAudio() async throws {
        let (services, meeting) = try await makeFixture()
        try await UtteranceRepository(services.database).append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 1000, text: "Valid speech", originDeviceId: "test-device"
        ))
        let model = TranscriptionModel(
            services: services, meetingId: meeting.id,
            asrFinish: {}, diarizationFinish: { throw CocoaError(.coderInvalidValue) }
        )
        try await model.finish()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.speakerWarning, RecordingLanguageText.speakerFailure)
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.map(\.text), ["Valid speech"])
        let saved = try await MeetingRepository(services.database).fetch(id: meeting.id)
        XCTAssertEqual(saved?.audioFileName, "recording.m4a")
    }

    private func makeFixture() async throws -> (AppServices, Meeting) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transcription-\(UUID().uuidString)", isDirectory: true)
        let services = try AppServices(
            database: .inMemory(), store: AudioFileStore.standard(applicationSupport: root)
        )
        let session = services.session
        addTeardownBlock {
            session.invalidate()
            try FileManager.default.removeItem(at: root)
        }
        let meeting = Meeting(
            id: UUID().uuidString, title: "BUG002",
            startedAt: Date(), originDeviceId: "test-device"
        )
        var meetingWithAudio = meeting
        meetingWithAudio.audioFileName = "recording.m4a"
        meetingWithAudio.audioByteCount = 42
        try await MeetingRepository(services.database).insert(meetingWithAudio)
        return (services, meetingWithAudio)
    }
}

private actor DrainProbe {
    private(set) var finished = false

    func markFinished() {
        finished = true
    }
}
