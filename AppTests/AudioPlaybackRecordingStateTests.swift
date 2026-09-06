import AVFoundation
import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class AudioPlaybackRecordingStateTests: XCTestCase {
    func testOnlyCurrentDetailMayOwnPlayback() throws {
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = AudioPlaybackModel(url: url, durationMs: 4_000)
        let second = AudioPlaybackModel(url: url, durationMs: 4_000)
        defer { first.stop(); second.stop() }
        first.play()
        XCTAssertTrue(first.isPlaying)
        second.play()
        XCTAssertTrue(second.isPlaying)
        XCTAssertFalse(first.isPlaying, "A new detail must synchronously revoke the previous player")
    }

    func testPlayingAudioStopsWhenRecordingBeginsAndCannotSeekWhileActive() throws {
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ownership = AudioSessionOwnership()
        let playback = AudioPlaybackModel(
            url: url,
            durationMs: 4_000,
            audioOwnership: ownership
        )
        XCTAssertEqual(playback.availability, .ready)

        playback.play()
        XCTAssertTrue(playback.isPlaying)
        try ownership.prepareForCapture()
        XCTAssertFalse(playback.isPlaying)
        let before = playback.currentTimeMs
        playback.seekAndPlay(toMs: 100)
        XCTAssertEqual(playback.currentTimeMs, before)

        ownership.releaseCapture()
        playback.seekAndPlay(toMs: 100)
        XCTAssertEqual(playback.currentTimeMs, 100)
        playback.stop()
    }

    func testProductionRecorderRevokesPlaybackBeforeCaptureAndRejectsLateDetailActions() async throws {
        let entered = expectation(description: "Permission boundary entered")
        let gate = PermissionGate(entered: entered)
        let fixture = try makeRecorder(requestPermission: { await gate.wait(); return .granted })
        let first = fixture.detail()
        let second = fixture.detail()
        first.playback.play()
        XCTAssertTrue(first.playback.isPlaying)
        second.playback.play()
        XCTAssertFalse(first.playback.isPlaying)
        XCTAssertTrue(second.playback.isPlaying)
        XCTAssertEqual(fixture.events.values, ["playback.activate", "playback.deactivate", "playback.activate"])

        let start = Task { await fixture.recorder.toggleRecording() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(fixture.recorder.phase, .starting)
        XCTAssertTrue(fixture.services.audioOwnership.isCaptureReserved)
        XCTAssertFalse(second.playback.isPlaying)
        XCTAssertEqual(fixture.events.values.last, "playback.deactivate")
        first.playback.stop()
        second.playback.seekAndPlay(toMs: 1_000)
        await fixture.recorder.toggleRecording() // Reentrant startup is ignored.
        XCTAssertFalse(fixture.events.values.contains("capture.start"))
        XCTAssertEqual(second.playback.currentTimeMs, 0)

        await gate.open()
        await start.value
        XCTAssertEqual(fixture.recorder.phase, .recording)
        XCTAssertEqual(fixture.events.values.suffix(2), ["playback.deactivate", "capture.start"])
        let duringCapture = fixture.events.values
        first.playback.stop()
        second.playback.stop()
        // Newly constructed details and retained title/saved-detail entries use the same owner.
        let late = fixture.detail()
        late.playback.play()
        first.playback.play()
        second.playback.seekAndPlay(toMs: 2_000)
        XCTAssertTrue(late.playback.isInteractionBlockedByRecording)
        XCTAssertEqual(fixture.events.values, duringCapture, "Old detail actions must not activate OR deactivate capture")

        await fixture.recorder.toggleRecording()
        XCTAssertEqual(fixture.recorder.phase, .idle)
        XCTAssertFalse(fixture.services.audioOwnership.isCaptureReserved)
        XCTAssertEqual(fixture.events.values.last, "capture.stop")
        let meetings = try await MeetingRepository(fixture.services.database).fetchAll()
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.state, .recorded)
        XCTAssertGreaterThan(meetings.first?.audioByteCount ?? 0, 0)
        second.playback.seekAndPlay(toMs: 1_000)
        XCTAssertTrue(second.playback.isPlaying)
        XCTAssertEqual(second.playback.currentTimeMs, 1_000)
        XCTAssertEqual(fixture.events.values.last, "playback.activate")
        let resumed = fixture.events.values
        first.playback.stop()
        late.playback.stop()
        XCTAssertEqual(fixture.events.values, resumed)
        second.playback.stop()
        XCTAssertEqual(fixture.events.values.last, "playback.deactivate")
    }

    func testCaptureStartupFailureReleasesReservationAndOldDetailCanResume() async throws {
        let fixture = try makeRecorder(failCaptureStart: true)
        let detail = fixture.detail()
        detail.playback.play()
        await fixture.recorder.toggleRecording()
        XCTAssertEqual(fixture.recorder.phase, .idle)
        XCTAssertNotNil(fixture.recorder.errorMessage)
        XCTAssertFalse(fixture.services.audioOwnership.isCaptureReserved)
        XCTAssertEqual(fixture.events.values.prefix(3), ["playback.activate", "playback.deactivate", "capture.start"])
        let before = fixture.events.values.count
        detail.playback.play()
        XCTAssertTrue(detail.playback.isPlaying)
        XCTAssertEqual(fixture.events.values.dropFirst(before), ["playback.activate"])
        detail.playback.stop()
    }

    func testPermissionDenialAndDeactivationFailureNeverStartCapture() async throws {
        let fixture = try makeRecorder(requestPermission: { .denied })
        let detail = fixture.detail()
        detail.playback.play()
        fixture.adapter.failDeactivation = true
        await fixture.recorder.toggleRecording()
        XCTAssertEqual(fixture.recorder.phase, .idle)
        XCTAssertFalse(fixture.events.values.contains("capture.start"))
        XCTAssertNotNil(fixture.recorder.errorMessage)
        fixture.adapter.failDeactivation = false
        await fixture.recorder.toggleRecording()
        XCTAssertEqual(fixture.recorder.permission, .denied)
        XCTAssertFalse(fixture.services.audioOwnership.isCaptureReserved)
        XCTAssertFalse(fixture.events.values.contains("capture.start"))
        detail.playback.play()
        XCTAssertTrue(detail.playback.isPlaying)
        detail.playback.stop()
    }

    func testInitialSeekOnlyRunsAfterFirstLoadAndReloadRetainsPlaybackPosition() async throws {
        let fixture = try makeRecorder()
        let meeting = Meeting(
            title: "Seek once", startedAt: Date(), durationMs: 4_000, originDeviceId: "test"
        )
        try await MeetingRepository(fixture.services.database).insert(meeting)
        try await UtteranceRepository(fixture.services.database).append([
            Utterance(id: "first", meetingId: meeting.id, startMs: 1_000, endMs: 1_500, text: "First", originDeviceId: "test"),
            Utterance(id: "second", meetingId: meeting.id, startMs: 2_000, endMs: 2_500, text: "Second", originDeviceId: "test")
        ])
        let detail = MeetingDetailModel(
            meeting: meeting, audioURL: fixture.url, services: fixture.services, initialSeekMs: 1_000
        )
        XCTAssertEqual(detail.playback.currentTimeMs, 0)
        XCTAssertTrue(fixture.events.values.isEmpty)
        await detail.load()
        detail.playback.pause()
        XCTAssertEqual(detail.playback.currentTimeMs, 1_000)
        XCTAssertEqual(detail.currentUtteranceId, "first")
        XCTAssertEqual(fixture.events.values, ["playback.activate"])
        detail.playback.seek(toMs: 2_000)
        detail.playback.stop() // Same boundary used when navigating away.
        let events = fixture.events.values
        await detail.load()
        XCTAssertEqual(detail.playback.currentTimeMs, 2_000)
        XCTAssertEqual(detail.currentUtteranceId, "second")
        XCTAssertFalse(detail.playback.isPlaying)
        XCTAssertEqual(fixture.events.values, events, "Reload must neither activate nor restart initial playback")
        let renamed = await detail.renameMeeting(newTitle: "Renamed")
        XCTAssertTrue(renamed)
        await detail.load()
        XCTAssertEqual(detail.playback.currentTimeMs, 2_000)
        XCTAssertEqual(detail.meeting.title, "Renamed")
        XCTAssertEqual(fixture.events.values, events)
    }

    func testInitialSeekConsumedWhileCapturingDoesNotJumpOnLaterReload() async throws {
        let fixture = try makeRecorder()
        let detail = MeetingDetailModel(
            meeting: Meeting(title: "Saved", startedAt: Date(), durationMs: 4_000, originDeviceId: "test"),
            audioURL: fixture.url, services: fixture.services, initialSeekMs: 1_000
        )
        await fixture.recorder.toggleRecording()
        await detail.load()
        XCTAssertEqual(detail.playback.currentTimeMs, 0)
        XCTAssertTrue(detail.playback.isInteractionBlockedByRecording)
        await fixture.recorder.toggleRecording()
        detail.playback.seek(toMs: 2_000)
        await detail.load()
        XCTAssertEqual(detail.playback.currentTimeMs, 2_000)
        XCTAssertFalse(detail.playback.isPlaying)
        XCTAssertFalse(fixture.events.values.contains("playback.activate"))
    }

    private func makeRecorder(
        failCaptureStart: Bool = false,
        requestPermission: @escaping () async -> MicrophonePermission.Status = { .granted }
    ) throws -> RecorderFixture {
        let events = AudioEvents()
        let adapter = PlaybackSessionSpy(events: events)
        let engine = OwnershipCaptureEngine(events: events, failStart: failCaptureStart)
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ownership-\(UUID().uuidString)", isDirectory: true)
        let services = try AppServices(
            database: .inMemory(), store: AudioFileStore.standard(applicationSupport: root),
            captureEngine: engine, audioOwnership: AudioSessionOwnership(session: adapter)
        )
        let url = try makeToneFile()
        addTeardownBlock {
            services.session.invalidate()
            try FileManager.default.removeItem(at: root)
            try FileManager.default.removeItem(at: url)
        }
        let recorder = RecorderModel(
            services: services, library: LibraryModel(services: services),
            activityController: NoRecordingActivity(), processing: NoModelTranscription(),
            requestPermission: requestPermission
        )
        return RecorderFixture(services: services, recorder: recorder, events: events, adapter: adapter, url: url)
    }

    @MainActor
    private struct RecorderFixture {
        let services: AppServices
        let recorder: RecorderModel
        let events: AudioEvents
        let adapter: PlaybackSessionSpy
        let url: URL

        func detail() -> MeetingDetailModel {
            MeetingDetailModel(
                meeting: Meeting(title: "Saved detail", startedAt: Date(), durationMs: 4_000, originDeviceId: "test"),
                audioURL: url, services: services
            )
        }
    }

    private final class AudioEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        var values: [String] { lock.withLock { entries } }
        func append(_ event: String) { lock.withLock { entries.append(event) } }
    }

    private enum OwnershipTestError: Error { case unavailable }

    @MainActor
    private final class PlaybackSessionSpy: PlaybackSessionControlling {
        let events: AudioEvents
        var failDeactivation = false
        init(events: AudioEvents) { self.events = events }
        func activate() { events.append("playback.activate") }
        func deactivate() throws {
            events.append("playback.deactivate")
            if failDeactivation { throw OwnershipTestError.unavailable }
        }
    }

    private final class OwnershipCaptureEngine: AudioCaptureControlling, @unchecked Sendable {
        let eventsLog: AudioEvents
        let failStart: Bool
        private let lock = NSLock()
        private var continuation: AsyncStream<AudioChunk>.Continuation?
        init(events: AudioEvents, failStart: Bool) { eventsLog = events; self.failStart = failStart }
        func chunks() -> AsyncStream<AudioChunk> {
            AsyncStream { value in lock.withLock { continuation = value } }
        }
        func levels() -> AsyncStream<AudioLevel> { AsyncStream { $0.finish() } }
        func events() -> AsyncStream<AudioCaptureEvent> { AsyncStream { $0.finish() } }
        func start() throws {
            eventsLog.append("capture.start")
            if failStart { throw OwnershipTestError.unavailable }
            lock.withLock {
                continuation?.yield(AudioChunk(
                    index: 0, startFrame: 0, sampleRate: 16_000,
                    samples: Array(repeating: 0, count: 1_600), isFinal: false
                ))
            }
        }
        func pause() throws {}
        func resume() throws {}
        @discardableResult
        func stop() -> Int {
            eventsLog.append("capture.stop")
            lock.withLock {
                continuation?.yield(AudioChunk(
                    index: 1, startFrame: 1_600, sampleRate: 16_000, samples: [], isFinal: true
                ))
            }
            return 1_600
        }
        func invalidate() { lock.withLock { continuation?.finish() } }
    }

    private actor PermissionGate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func open() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    private struct NoModelTranscription: RecordingTranscriptionControlling {
        var isAvailable: Bool { true }
        func refreshAvailability() {}
        func start(meetingId: String, chunks: AsyncStream<AudioChunk>, diarizationChunks: AsyncStream<AudioChunk>) throws {}
        func finish() async throws {}
        func discard() async {}
    }

    @MainActor
    private final class NoRecordingActivity: RecordingActivityControlling {
        func cleanupOrphans() async {}
        func start(meetingId: String) async {}
        func update(meetingId: String, elapsed: TimeInterval, recentTranscriptLines: [String], isPaused: Bool) async {}
        func end(meetingId: String) async {}
    }

    private func makeToneFile() throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("review-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let sampleRate: UInt32 = 8_000
        let samples = Array(repeating: Int16(0), count: 32_000)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + samples.count * 2), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(sampleRate, to: &data)
        appendLE(sampleRate * 2, to: &data)
        appendLE(UInt16(2), to: &data)
        appendLE(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(samples.count * 2), to: &data)
        for sample in samples { appendLE(UInt16(bitPattern: sample), to: &data) }
        try data.write(to: url)
        return url
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
