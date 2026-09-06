import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import TranscriptCore

@Suite struct RecordingSealTests {
    @Test func sealPopulatesAllFourFieldsAndTheState() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)
        #expect(meeting.durationMs == 0)

        let sealed = try await repo.sealRecording(
            id: meeting.id,
            durationMs: 94_500,
            audio: SealedAudio(fileName: "\(meeting.id).m4a", sha256: String(repeating: "b", count: 64), byteCount: 512_000),
            deviceId: testiPhoneId
        )

        #expect(sealed.state == .recorded)
        #expect(sealed.durationMs == 94_500)
        #expect(sealed.audioFileName == "\(meeting.id).m4a")
        #expect(sealed.audioSHA256 == String(repeating: "b", count: 64))
        #expect(sealed.audioByteCount == 512_000)

        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.state == .recorded)
        #expect(stored.durationMs == sealed.durationMs)
        #expect(stored.audioFileName == sealed.audioFileName)
        #expect(stored.audioSHA256 == sealed.audioSHA256)
        #expect(stored.audioByteCount == sealed.audioByteCount)
    }

    @Test func anIllegalTransitionLeavesEveryFieldUntouched() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)
        try await repo.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        try await repo.transition(id: meeting.id, to: .audioSynced, deviceId: testiPhoneId)

        await #expect(throws: IllegalMeetingStateTransition.self) {
            try await repo.sealRecording(
                id: meeting.id,
                durationMs: 1_000,
                audio: SealedAudio(fileName: "x.m4a", sha256: "deadbeef", byteCount: 9),
                deviceId: testiPhoneId
            )
        }

        // Atomic: the rejected transition must not have written the audio columns either.
        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.state == .audioSynced)
        #expect(stored.durationMs == 0)
        #expect(stored.audioFileName == nil)
        #expect(stored.audioSHA256 == nil)
        #expect(stored.audioByteCount == nil)
    }

    @Test func sealingIntoFailedKeepsThePartialAudioAndDuration() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        let partial = SealedAudio(fileName: "\(meeting.id).m4a", sha256: "abc123", byteCount: 4_096)
        let failed = try await repo.sealRecording(
            id: meeting.id, to: .failed, durationMs: 7_000, audio: partial, deviceId: testiPhoneId
        )
        #expect(failed.state == .failed)
        #expect(failed.failedFromState == .recording)
        #expect(failed.durationMs == 7_000)
        #expect(failed.audioSHA256 == "abc123")

        // PLAN §3.2.1: the remains of a crashed recording can be settled as a short meeting.
        let salvaged = try await repo.sealRecording(
            id: meeting.id, to: .recorded, durationMs: 7_000, audio: partial, deviceId: testiPhoneId
        )
        #expect(salvaged.state == .recorded)
        #expect(salvaged.durationMs == 7_000)
        #expect(salvaged.audioByteCount == 4_096)
    }

    @Test func sealingWithoutAudioStillWritesTheDuration() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        let failed = try await repo.sealRecording(
            id: meeting.id, to: .failed, durationMs: 3_200, audio: nil, deviceId: testiPhoneId
        )
        #expect(failed.durationMs == 3_200)
        #expect(failed.audioFileName == nil)
    }

    @Test func durationComesFromCapturedFrames() {
        #expect(RecordingSession.durationMs(frames: 35_840, sampleRate: 16_000) == 2_240)
        #expect(RecordingSession.durationMs(frames: 0, sampleRate: 16_000) == 0)
        #expect(RecordingSession.durationMs(frames: 16_000, sampleRate: 0) == 0)
    }

    @Test func pendingStopTokenIdentifiesTheMeetingBeingPublished() {
        let token = RecordingSession.PendingStop(meetingId: "pending-meeting")
        #expect(token.meetingId == "pending-meeting")
    }
}

@Suite struct RecordingRecoveryTests {
    @Test func salvagesACrashedRecordingWithItsPartialDuration() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AudioFileStore(directory: directory)

        let meeting = makeTestMeeting(title: "crashed")
        try await repo.insert(meeting)
        // A process that died left audio behind but never sealed the row.
        let fileName = try store.fileName(for: meeting.id)
        try Data(repeating: 7, count: 2_048).write(to: try store.url(forFileName: fileName))

        let recovery = RecordingRecovery(
            database: db, deviceId: testiPhoneId, store: store,
            inspector: StubInspector(durationMs: 11_500)
        )
        let salvaged = try await recovery.salvageInterruptedRecordings()

        #expect(salvaged.count == 1)
        let recovered = try #require(salvaged.first)
        #expect(recovered.state == .recorded)
        #expect(recovered.failedFromState == nil)
        #expect(recovered.durationMs == 11_500)
        #expect(recovered.audioFileName == fileName)
        #expect(recovered.audioByteCount == 2_048)
        #expect(recovered.audioSHA256 == IncrementalSHA256.hex(SHA256.hash(data: Data(repeating: 7, count: 2_048))))
    }

    @Test func aCrashWithNoAudioStaysRecoverableRatherThanBecomingAZeroLengthRecording() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        let recovery = RecordingRecovery(
            database: db, deviceId: testiPhoneId, store: AudioFileStore(directory: directory)
        )
        let salvaged = try await recovery.salvageInterruptedRecordings()

        #expect(salvaged.count == 1)
        #expect(salvaged.first?.state == .failed)
        #expect(salvaged.first?.failedFromState == .recording)
    }

    @Test func theRecordingInFlightIsNotSalvagedOutFromUnderItself() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = makeTestMeeting(title: "live")
        try await repo.insert(live)
        let recovery = RecordingRecovery(
            database: db, deviceId: testiPhoneId, store: AudioFileStore(directory: directory)
        )

        #expect(try await recovery.salvageInterruptedRecordings(excluding: [live.id]).isEmpty)
        #expect(try await repo.fetch(id: live.id)?.state == .recording)
    }

    @Test func inspectorReadsDurationAndHashFromARealFile() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("partial.m4a")

        let writer = try AudioFileWriter(url: url, segmentSeconds: 1)
        try writer.start()
        let format = AudioCaptureFormat.makeProcessingFormat()
        var buffer = AudioChunkBuffer(tier: .nemotron2240ms)
        for chunk in buffer.append(try sineSamples(format: format, frames: 48_000, startFrame: 0)) {
            try await writer.append(chunk)
        }
        try await writer.append(buffer.finish())
        let sealed = try await writer.finish()

        let inspected = try await AudioFileInspector().inspect(url: url, fileName: "partial.m4a")
        #expect(inspected.audio == sealed)
        #expect(abs(inspected.durationMs - 3_000) < 200)
    }
}

private struct StubInspector: AudioFileInspecting {
    let durationMs: Int

    func inspect(url: URL, fileName: String) throws -> InspectedAudio {
        let hashed = try IncrementalSHA256.hashFile(at: url)
        return InspectedAudio(
            durationMs: durationMs,
            audio: SealedAudio(fileName: fileName, sha256: hashed.sha256, byteCount: hashed.byteCount)
        )
    }
}
