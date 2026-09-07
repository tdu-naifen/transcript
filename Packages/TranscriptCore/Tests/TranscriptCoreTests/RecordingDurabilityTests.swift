import AVFoundation
import Foundation
import Testing
import GRDB
@testable import TranscriptCore

@Suite struct RecordingDurabilityTests {
    @Test func publicationReadFailureReleasesOnlyCompletedMeetingAndAllowsRetryAndDeletion() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        defer { try? database.writer.close() }
        let session = RecordingSession(
            database: database, deviceId: "durability-test", store: AudioFileStore(directory: directory),
            captureEngine: DurabilityCaptureEngine(seconds: 2)
        )
        let a = try await session.start(title: "A")
        let token = try await session.drainCapture()
        let b = try await session.start(title: "B")
        try await database.writer.write { try $0.execute(sql: "ALTER TABLE meeting RENAME TO unavailableMeeting") }
        await #expect(throws: (any Error).self) { try await session.publish(token, as: .recorded) }
        #expect(!(await session.isProcessing(meetingId: a.id)))
        #expect(await session.activeMeetingId == b.id)
        try await database.writer.write { try $0.execute(sql: "ALTER TABLE unavailableMeeting RENAME TO meeting") }
        #expect(try await session.publish(token, as: .recorded).id == a.id)
        let retry = try await session.beginProcessing(meetingId: a.id)
        _ = try await session.publish(token, as: .recorded)
        #expect(await session.isProcessing(meetingId: a.id), "An old acknowledgment cannot clear a newer reservation")
        _ = try await session.publish(retry, as: .recorded)
        try await MeetingRepository(database).delete(id: a.id)
        #expect(try await MeetingRepository(database).fetch(id: a.id) == nil)
        #expect(await session.activeMeetingId == b.id)
        _ = try await session.stop()
    }

    @Test func cancelledLanguageBoundaryCannotPersistAMixedLanguagePolicy() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Language boundary", startedAt: Date(), originDeviceId: "test")
        let jobs = RecordingProcessingRepository(database)
        try await jobs.insertRecording(meeting, localeIdentifier: "en-US")
        let cancelled = RecordingLanguageBoundary()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await jobs.commitLanguageBoundary(
                meetingId: meeting.id, previousLocale: "en-US", newLocale: "zh-CN", boundary: cancelled
            )
        }
        #expect(try await jobs.fetch(meetingId: meeting.id)?.requiresSegmentedRetry == false)
        try await jobs.commitLanguageBoundary(
            meetingId: meeting.id, previousLocale: nil, newLocale: "zh-CN", boundary: RecordingLanguageBoundary()
        )
        #expect(try await jobs.fetch(meetingId: meeting.id)?.requiresSegmentedRetry == false)
        #expect(try await jobs.fetch(meetingId: meeting.id)?.localeIdentifier == "zh-CN")
        try await jobs.commitLanguageBoundary(
            meetingId: meeting.id, previousLocale: "zh-CN", newLocale: "en-US", boundary: RecordingLanguageBoundary()
        )
        #expect(try await jobs.fetch(meetingId: meeting.id)?.requiresSegmentedRetry == true)
    }

    @Test func durableArchiveReleasesCaptureButKeepsIndependentProcessingReservations() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        defer { try? database.writer.close() }
        let session = RecordingSession(
            database: database, deviceId: "durability-test", store: AudioFileStore(directory: directory),
            captureEngine: DurabilityCaptureEngine(seconds: 2)
        )
        let first = try await session.start(title: "A", localeIdentifier: "en-US")
        let tokenA = try await session.drainCapture()
        #expect(await session.activeMeetingId == nil)
        #expect(await session.isProcessing(meetingId: first.id))
        let second = try await session.start(title: "B", localeIdentifier: "zh-CN")
        let tokenB = try await session.drainCapture()
        let third = try await session.start(title: "C")
        #expect(await session.processingMeetingIDs == [first.id, second.id])
        _ = try await session.publish(tokenA, as: .failed)
        _ = try await session.publish(tokenA, as: .recorded)
        #expect(await session.activeMeetingId == third.id)
        #expect(await session.isProcessing(meetingId: second.id))
        #expect(!(await session.isProcessing(meetingId: first.id)))
        _ = try await session.publish(tokenB, as: .recorded)
        _ = try await session.stop()
        for id in [first.id, second.id, third.id] {
            let saved = try #require(try await MeetingRepository(database).fetch(id: id))
            #expect(saved.durationMs == 2_000)
            #expect(saved.audioSHA256 != nil)
        }
    }

    @Test func interruptedLocalJobsPreserveTextAudioAndLanguagePolicyWithoutResurrection() async throws {
        let directory = try durabilityDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        let store = AudioFileStore(directory: directory)
        let session = RecordingSession(
            database: database, deviceId: "durability-test", store: store,
            captureEngine: DurabilityCaptureEngine(seconds: 2)
        )
        let meeting = try await session.start(title: "Interrupted", localeIdentifier: "en-US")
        let utterance = Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 900, text: "Edited partial text",
            localeIdentifier: "en-US", revision: 4, originDeviceId: "durability-test"
        )
        try await UtteranceRepository(database).append(utterance)
        _ = try await session.drainCapture()
        let jobs = RecordingProcessingRepository(database)
        try await jobs.markLanguageChange(meetingId: meeting.id)
        try await jobs.update(meetingId: meeting.id, state: .processing)
        let bytes = try Data(contentsOf: store.url(for: meeting.id))
        let previous = try await MeetingRepository(database).fetch(id: meeting.id)
        let text = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        try database.writer.close()
        let reopened = try AppDatabase.onDisk(directory: directory)
        defer { try? reopened.writer.close() }
        let recoveredJobs = RecordingProcessingRepository(reopened)
        try await recoveredJobs.interruptUnfinished()
        let job = try #require(try await recoveredJobs.fetch(meetingId: meeting.id))
        #expect(job.state == .interrupted)
        #expect(job.localeIdentifier == "en-US")
        #expect(job.requiresSegmentedRetry)
        #expect(job.audioSHA256 == previous?.audioSHA256)
        #expect(try await MeetingRepository(reopened).fetch(id: meeting.id) == previous)
        #expect(try await UtteranceRepository(reopened).fetch(meetingId: meeting.id) == text)
        #expect(try Data(contentsOf: store.url(for: meeting.id)) == bytes)
        try await MeetingRepository(reopened).delete(id: meeting.id)
        try await recoveredJobs.update(meetingId: meeting.id, state: .complete)
        #expect(try await recoveredJobs.fetch(meetingId: meeting.id) == nil)
        #expect(try await MeetingRepository(reopened).fetch(id: meeting.id) == nil)
    }

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
