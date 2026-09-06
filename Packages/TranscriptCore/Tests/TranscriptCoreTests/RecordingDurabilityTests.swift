import AVFoundation
import Foundation
import Testing
import GRDB
@testable import TranscriptCore

@Suite struct RecordingDurabilityTests {
    @Test func recoveryLeavesSealedFailuresAndRemoteRecordingsUntouched() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        defer { try? database.writer.close() }
        let store = AudioFileStore(directory: directory)
        let repository = MeetingRepository(database)
        let legacy = Meeting(
            title: "Legacy processing failure", startedAt: Date(),
            durationMs: 99_000, audioFileName: "existing.m4a", audioSHA256: "existing-hash",
            audioByteCount: 999, state: .failed, failedFromState: .recording,
            originDeviceId: "durability-test"
        )
        let postprocessing = Meeting(
            title: "Later processing failure", startedAt: Date(),
            state: .failed, failedFromState: .analyzing, originDeviceId: "durability-test"
        )
        let remote = Meeting(title: "Remote recording", startedAt: Date(), originDeviceId: "other-device")
        for meeting in [legacy, postprocessing, remote] { try await repository.insert(meeting) }
        try Data("unreadable but irreplaceable".utf8).write(to: store.url(forFileName: "existing.m4a"))
        let original = try await repository.fetchAll()
        let recovered = try await RecordingRecovery(
            database: database, deviceId: "durability-test", store: store,
            inspector: UnavailableDurabilityInspector()
        ).salvageInterruptedRecordings()
        #expect(recovered.isEmpty)
        #expect(try await repository.fetchAll() == original)
        #expect(try Data(contentsOf: store.url(forFileName: "existing.m4a")) == Data("unreadable but irreplaceable".utf8))
    }

    @Test func encoderCompletionDeadlineDoesNotWaitForLateCallback() async throws {
        let callback = FinishCallbackBox()
        await #expect(throws: AudioCaptureError.self) {
            try await AudioWriterFinishWait.wait(timeout: 0.01) { callback.set($0) }
        }
        callback.call()
        callback.call()
        try await AudioWriterFinishWait.wait(timeout: 1) { $0() }
    }

    @Test func aWriterNeverOverwritesExistingAudio() throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.m4a")
        let bytes = Data("irreplaceable audio".utf8)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try AudioFileWriter(url: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func pendingSealSurvivesDatabaseFailureAndPublicationIsIdempotent() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        defer { try? database.writer.close() }
        let store = AudioFileStore(directory: directory)
        let session = RecordingSession(
            database: database, deviceId: "durability-test", store: store,
            captureEngine: DurabilityCaptureEngine(seconds: 2)
        )
        let first = try await session.start(title: "First")
        try await database.writer.write {
            try $0.execute(sql: """
                CREATE TRIGGER rejectSeal BEFORE UPDATE OF audioFileName ON meeting
                BEGIN SELECT RAISE(FAIL, 'simulated disk failure'); END
                """)
        }
        await #expect(throws: (any Error).self) { try await session.drainCapture() }
        #expect(await session.activeMeetingId == first.id)
        #expect(try await MeetingRepository(database).fetch(id: first.id)?.state == .recording)
        let bytes = try Data(contentsOf: store.url(for: first.id))
        await #expect(throws: AudioCaptureError.self) { try await session.start(title: "Rejected") }
        try await database.writer.write { try $0.execute(sql: "DROP TRIGGER rejectSeal") }
        let token = try await session.drainCapture()
        let acknowledged = try await session.publish(token, as: .failed)
        #expect(acknowledged.state == .recorded)
        #expect(try await session.publish(token, as: .recorded) == acknowledged)
        let second = try await session.start(title: "Second")
        #expect(try await session.publish(token, as: .failed).id == first.id)
        #expect(await session.activeMeetingId == second.id)
        let secondSealed = try await session.stop()
        #expect(try Data(contentsOf: store.url(for: first.id)) == bytes)
        try await MeetingRepository(database).delete(id: first.id)
        await #expect(throws: (any Error).self) { try await session.publish(token, as: .recorded) }
        #expect(try await MeetingRepository(database).fetch(id: second.id)?.state == .recorded)
        try database.writer.close()
        let reopened = try AppDatabase.onDisk(directory: directory)
        defer { try? reopened.writer.close() }
        let afterPublication = try #require(try await MeetingRepository(reopened).fetch(id: second.id))
        #expect(afterPublication.state == .recorded)
        #expect(afterPublication.durationMs == secondSealed.durationMs)
        #expect(afterPublication.audioSHA256 == secondSealed.audioSHA256)
    }

    @Test func crashBeforeWriterFinishRecoversExistingFragmentsWithoutRewriting() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        defer { try? database.writer.close() }
        let store = AudioFileStore(directory: directory)
        let meeting = Meeting(title: "Fragment crash", startedAt: Date(), originDeviceId: "durability-test")
        let untouched = Meeting(title: "Existing", startedAt: Date(), state: .recorded, originDeviceId: "other")
        let repository = MeetingRepository(database)
        try await repository.insert(meeting)
        try await repository.insert(untouched)
        let unchangedMeeting = try await repository.fetch(id: untouched.id)
        let speaker = try await SpeakerRepository(database).createAnonymousSpeaker(deviceId: "other")
        let embedding = SpeakerEmbedding(speakerId: speaker.id, floats: Array(repeating: 0.1, count: 192))
        try await SpeakerRepository(database).addEmbedding(embedding)
        let originalEmbeddings = try await database.reader.read { try SpeakerEmbedding.fetchAll($0) }
        try await UtteranceRepository(database).append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 500, text: "Partial transcript",
            originDeviceId: "durability-test"
        ))
        let writer = try await makeDurabilityAudio(at: store.url(for: meeting.id), seconds: 8)
        for _ in 0..<100 {
            if (try Data(contentsOf: writer.url)).count > 4_000 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        writer.abandon()
        let bytes = try Data(contentsOf: writer.url)
        #expect(bytes.count > 4_000)
        let inspectionStarted = ContinuousClock.now
        let fragmentDuration = try await AudioFileInspector.fragmentDuration(url: writer.url)
        #expect(fragmentDuration > 3_000)
        print("FRAGMENT_RECOVERY durationMs=\(fragmentDuration) decode=\(inspectionStarted.duration(to: .now))")
        try database.writer.close()
        let reopened = try AppDatabase.onDisk(directory: directory)
        defer { try? reopened.writer.close() }
        let recovered = try await RecordingRecovery(
            database: reopened, deviceId: "durability-test", store: store
        ).salvageInterruptedRecordings()
        #expect(recovered.count == 1)
        #expect(recovered.first?.state == .recorded)
        #expect((recovered.first?.durationMs ?? 0) > 3_000)
        #expect(try Data(contentsOf: writer.url) == bytes)
        let rows = try await UtteranceRepository(reopened).fetch(meetingId: meeting.id)
        #expect(rows.map(\.text) == ["Partial transcript"])
        #expect(try await MeetingRepository(reopened).fetch(id: untouched.id) == unchangedMeeting)
        #expect(try await reopened.reader.read { try SpeakerEmbedding.fetchAll($0) } == originalEmbeddings)
        #expect(try await RecordingRecovery(
            database: reopened, deviceId: "durability-test", store: store
        ).salvageInterruptedRecordings().isEmpty)
    }

    @Test func ninetyNineSecondArchiveIsDurableBeforeProcessingOrPublish() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        defer { try? database.writer.close() }
        let store = AudioFileStore(directory: directory)
        let session = RecordingSession(
            database: database, deviceId: "durability-test", store: store,
            captureEngine: DurabilityCaptureEngine(seconds: 99)
        )
        let meeting = try await session.start(title: "99 second archive")
        let started = ContinuousClock.now
        let pending = try await session.drainCapture()
        let archiveElapsed = started.duration(to: .now)
        #expect(pending.meetingId == meeting.id)
        try database.writer.close()
        let reopened = try AppDatabase.onDisk(directory: directory)
        defer { try? reopened.writer.close() }
        let saved = try #require(try await MeetingRepository(reopened).fetch(id: meeting.id))
        print("DURABILITY archive=\(archiveElapsed) state=\(saved.state) durationMs=\(saved.durationMs)")
        #expect(saved.state == .recorded)
        #expect(saved.durationMs == 99_000)
        #expect(saved.audioFileName == "\(meeting.id).m4a")
        let hashed = try IncrementalSHA256.hashFile(at: store.url(for: meeting.id))
        #expect(saved.audioSHA256 == hashed.sha256)
        #expect(saved.audioByteCount == hashed.byteCount)
        #expect(hashed.byteCount > 0)
        #expect(abs(saved.startedAt.timeIntervalSince(meeting.startedAt)) < 0.001)
        #expect(abs(saved.createdAt.timeIntervalSince(meeting.createdAt)) < 0.001)
    }

    private final class FinishCallbackBox: @unchecked Sendable {
        let lock = NSLock()
        var callback: (@Sendable () -> Void)?
        func set(_ callback: @escaping @Sendable () -> Void) { lock.withLock { self.callback = callback } }
        func call() { lock.withLock { callback }?() }
    }

    @Test func recoveryRetriesAnOldFailedRowAfterInspectionFailure() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        defer { try? database.writer.close() }
        let store = AudioFileStore(directory: directory)
        let repository = MeetingRepository(database)
        let meeting = Meeting(title: "Interrupted", startedAt: Date(), originDeviceId: "durability-test")
        try await repository.insert(meeting)
        let writer = try await makeDurabilityAudio(at: store.url(for: meeting.id), seconds: 3)
        let sealed = try await writer.finish()
        let before = try Data(contentsOf: store.url(for: meeting.id))
        _ = try await repository.sealRecording(
            id: meeting.id, to: .failed, durationMs: 0, audio: nil, deviceId: "durability-test"
        )
        let failedRecovery = RecordingRecovery(
            database: database, deviceId: "durability-test", store: store,
            inspector: UnavailableDurabilityInspector()
        )
        await #expect(throws: (any Error).self) {
            try await failedRecovery.salvageInterruptedRecordings()
        }
        #expect(try Data(contentsOf: store.url(for: meeting.id)) == before)
        #expect(try await repository.fetch(id: meeting.id)?.audioFileName == nil)

        try database.writer.close()
        let reopened = try AppDatabase.onDisk(directory: directory)
        defer { try? reopened.writer.close() }
        let recovered = try await RecordingRecovery(
            database: reopened, deviceId: "durability-test", store: store
        ).salvageInterruptedRecordings()
        #expect(recovered.count == 1)
        #expect(recovered.first?.state == .recorded)
        #expect(recovered.first?.audioSHA256 == sealed.sha256)
        #expect((recovered.first?.durationMs ?? 0) > 2_800)
    }
}

private struct UnavailableDurabilityInspector: AudioFileInspecting {
    func inspect(url: URL, fileName: String) throws -> InspectedAudio {
        throw CocoaError(.fileReadNoPermission)
    }
}

private func durabilityDirectory() throws -> URL {
    #if os(iOS)
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    #else
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    #endif
    let directory = root.appendingPathComponent(".durability-test-artifacts/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeDurabilityAudio(at url: URL, seconds: Int) async throws -> AudioFileWriter {
    let writer = try AudioFileWriter(url: url, segmentSeconds: 1)
    try writer.start()
    for second in 0..<seconds {
        try await writer.append(durabilityChunk(second: second))
    }
    return writer
}

private func durabilityChunk(second: Int) -> AudioChunk {
    AudioChunk(
        index: second, startFrame: second * 16_000, sampleRate: 16_000,
        samples: (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.1 },
        isFinal: false
    )
}

private final class DurabilityCaptureEngine: AudioCaptureControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    let seconds: Int

    init(seconds: Int) { self.seconds = seconds }
    func chunks() -> AsyncStream<AudioChunk> {
        AsyncStream { stream in lock.withLock { continuation = stream } }
    }
    func levels() -> AsyncStream<AudioLevel> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<AudioCaptureEvent> { AsyncStream { $0.finish() } }
    func start() throws {
        let stream = lock.withLock { continuation }
        for second in 0..<seconds { stream?.yield(durabilityChunk(second: second)) }
    }
    func pause() throws {}
    func resume() throws {}
    @discardableResult func stop() -> Int {
        lock.withLock {
            continuation?.yield(AudioChunk(
                index: seconds, startFrame: seconds * 16_000, sampleRate: 16_000,
                samples: [], isFinal: true
            ))
            continuation?.finish()
        }
        return seconds * 16_000
    }
    func invalidate() { lock.withLock { continuation?.finish() } }
}
