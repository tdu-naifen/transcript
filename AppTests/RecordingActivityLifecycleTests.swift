import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class RecordingActivityLifecycleTests: XCTestCase {
    func testCaptureStopsBeforeSuspendedActivityEndAndPausedStopIsIdempotent() async throws {
        let entered = expectation(description: "Activity end entered")
        let gate = LifecycleGate(entered: entered)
        let activity = ActivitySpy(endGate: gate)
        let fixture = try await makeFixture(activity: activity)
        await fixture.recorder.togglePause()
        XCTAssertEqual(fixture.recorder.phase, .paused)

        let stop = Task { await fixture.recorder.toggleRecording() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(fixture.recorder.phase, .stopping)
        let protectedID = await fixture.services.session.activeMeetingId
        XCTAssertEqual(protectedID, fixture.meeting.id)
        let deletion = await LibraryModel(services: fixture.services).delete(fixture.meeting)
        XCTAssertFalse(deletion, "A draining recording must remain protected until publication")
        await fixture.recorder.toggleRecording()
        XCTAssertNil(fixture.recorder.requestStop())
        XCTAssertEqual(activity.ending, [fixture.meeting.id])

        await gate.open()
        await stop.value
        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(fixture.recorder.phase, .idle)
        let stored = try await MeetingRepository(fixture.services.database).fetch(id: fixture.meeting.id)
        XCTAssertEqual(stored?.state, .recorded)
        XCTAssertGreaterThan(stored?.audioByteCount ?? 0, 0)
    }

    func testActivityEndsWhileTranscriptionStillDrains() async throws {
        let entered = expectation(description: "ASR drain entered")
        let gate = LifecycleGate(entered: entered)
        let activity = ActivitySpy()
        let fixture = try await makeFixture(activity: activity, asrFinish: { await gate.wait() })

        let stop = Task { await fixture.recorder.toggleRecording() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(activity.ended, [fixture.meeting.id])
        XCTAssertEqual(fixture.recorder.phase, .processing)
        XCTAssertFalse(fixture.recorder.isBusy)
        XCTAssertTrue(fixture.recorder.isProcessingTranscript)
        XCTAssertFalse(fixture.recorder.canStartRecording)
        let draining = try await MeetingRepository(fixture.services.database).fetch(id: fixture.meeting.id)
        XCTAssertEqual(draining?.state, .recorded)
        XCTAssertEqual(draining?.durationMs, 100)
        XCTAssertGreaterThan(draining?.audioByteCount ?? 0, 0)
        await fixture.recorder.toggleRecording()
        XCTAssertEqual(fixture.engine.stopCount, 1)
        let protectedID = await fixture.services.session.activeMeetingId
        XCTAssertEqual(protectedID, fixture.meeting.id)

        await gate.open()
        await stop.value
        let stored = try await MeetingRepository(fixture.services.database).fetch(id: fixture.meeting.id)
        XCTAssertEqual(stored?.state, .recorded)
        XCTAssertFalse(fixture.recorder.isProcessingTranscript)
        XCTAssertTrue(fixture.recorder.canStartRecording)
    }

    func testNinetyNineSecondDiskArchiveReopensWhileASRIsHeld() async throws {
        let entered = expectation(description: "Held ASR entered after durable archive")
        let gate = LifecycleGate(entered: entered)
        let fixture = try await makeFixture(asrFinish: { await gate.wait() }, frameCount: 99 * 16_000)
        let started = ContinuousClock.now
        let stop = Task { await fixture.recorder.toggleRecording() }
        await fulfillment(of: [entered], timeout: 10)
        let archiveElapsed = started.duration(to: .now)
        let root = fixture.services.store.directory.deletingLastPathComponent().deletingLastPathComponent()
        let reopened = try AppDatabase.onDisk(directory: root)
        defer { try? reopened.writer.close() }
        let stored = try await MeetingRepository(reopened).fetch(id: fixture.meeting.id)
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row.state, .recorded)
        XCTAssertEqual(row.durationMs, 99_000)
        let hash = try IncrementalSHA256.hashFile(at: fixture.services.store.url(for: row.id))
        XCTAssertEqual(row.audioSHA256, hash.sha256)
        XCTAssertEqual(row.audioByteCount, hash.byteCount)
        XCTAssertEqual(row.audioFileName, "\(row.id).m4a")
        XCTAssertFalse(fixture.recorder.isBusy)
        XCTAssertTrue(fixture.recorder.audioArchiveSaved)
        XCTAssertFalse(fixture.recorder.canStartRecording)
        let deletion = await LibraryModel(services: fixture.services).delete(row)
        XCTAssertFalse(deletion)
        await gate.open()
        await stop.value
        print("DURABILITY_APP archive=\(archiveElapsed) processingComplete=\(started.duration(to: .now))")
    }

    func testGeneralProcessingFailureCannotDowngradeDurableAudio() async throws {
        let fixture = try await makeFixture(asrFinish: { throw CocoaError(.fileReadUnknown) })
        await fixture.recorder.toggleRecording()
        let row = try await MeetingRepository(fixture.services.database).fetch(id: fixture.meeting.id)
        XCTAssertEqual(row?.state, .recorded)
        XCTAssertGreaterThan(row?.audioByteCount ?? 0, 0)
        XCTAssertNotNil(fixture.recorder.errorMessage)
        XCTAssertTrue(fixture.recorder.canStartRecording)
    }

    func testCaptureFailureEndsActivityAndPreservesFailedRecording() async throws {
        let activity = ActivitySpy()
        let fixture = try await makeFixture(activity: activity)
        let stop = try XCTUnwrap(fixture.recorder.handleCaptureEvent(.failed(message: "Route failed")))
        await stop.value

        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(activity.ended, [fixture.meeting.id])
        XCTAssertEqual(fixture.recorder.phase, .idle)
        XCTAssertEqual(fixture.recorder.errorMessage, "Route failed")
        let stored = try await MeetingRepository(fixture.services.database).fetch(id: fixture.meeting.id)
        XCTAssertEqual(stored?.state, .failed)
        XCTAssertEqual(stored?.title, fixture.meeting.title)
        XCTAssertGreaterThan(stored?.audioByteCount ?? 0, 0)
        let rows = try await UtteranceRepository(fixture.services.database).fetch(meetingId: fixture.meeting.id)
        XCTAssertEqual(rows.map(\.text), ["Preserved text"])
    }

    func testCancelledRequesterDoesNotCancelStopDrain() async throws {
        let fixture = try await makeFixture(asrFinish: { try Task.checkCancellation() })
        let requester = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return fixture.recorder.requestStop()
        }
        let requested = await requester.value
        let stop = try XCTUnwrap(requested)
        await stop.value
        XCTAssertFalse(stop.isCancelled)
        let stored = try await MeetingRepository(fixture.services.database).fetch(id: fixture.meeting.id)
        XCTAssertEqual(stored?.state, .recorded)
        XCTAssertEqual(fixture.engine.stopCount, 1)
    }

    func testSpeechFailureDoesNotMarkSuccessfullySealedAudioAsFailed() async throws {
        let fixture = try await makeFixture(asrFinish: { throw RecordingSpeechUnavailable() })
        await fixture.recorder.toggleRecording()
        let stored = try await MeetingRepository(fixture.services.database).fetch(id: fixture.meeting.id)
        XCTAssertEqual(stored?.state, .recorded)
        XCTAssertGreaterThan(stored?.audioByteCount ?? 0, 0)
        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(fixture.recorder.errorMessage, RecordingSpeechUnavailable().localizedDescription)
        let rows = try await UtteranceRepository(fixture.services.database).fetch(meetingId: fixture.meeting.id)
        XCTAssertEqual(rows.map(\.text), ["Preserved text"])
    }

    func testLateEndAndUpdateCannotAffectNextActivity() async throws {
        let entered = expectation(description: "Old end entered")
        let gate = LifecycleGate(entered: entered)
        let backend = ActivityBackend()
        backend.endGates["old"] = gate
        let controller = backend.controller()
        await controller.start(meetingId: "old")
        let oldEnd = Task { await controller.end(meetingId: "old") }
        await fulfillment(of: [entered], timeout: 5)

        await controller.start(meetingId: "new")
        await controller.end(meetingId: "old")
        await controller.update(meetingId: "old", elapsed: 4, recentTranscriptLines: [], isPaused: false)
        await gate.open()
        await oldEnd.value
        await controller.update(meetingId: "new", elapsed: 1, recentTranscriptLines: [], isPaused: false)

        XCTAssertEqual(backend.requested, ["old", "new"])
        XCTAssertEqual(backend.ending, ["old"])
        XCTAssertEqual(backend.updated, ["new"])
        await controller.end(meetingId: "new")
        await controller.update(meetingId: "new", elapsed: 2, recentTranscriptLines: [], isPaused: false)
        XCTAssertEqual(backend.updated, ["new"])
    }

    func testOrphanCleanupSnapshotExcludesNewActivitiesAndRunsOnce() async throws {
        let entered = expectation(description: "Orphan end entered")
        let gate = LifecycleGate(entered: entered)
        let backend = ActivityBackend()
        backend.existingIDs = ["orphan"]
        backend.endGates["orphan"] = gate
        let controller = backend.controller()
        let cleanup = Task { await controller.cleanupOrphans() }
        await fulfillment(of: [entered], timeout: 5)

        await controller.start(meetingId: "new")
        backend.existingIDs.append("new")
        await controller.cleanupOrphans()
        await gate.open()
        await cleanup.value
        await controller.update(meetingId: "new", elapsed: 1, recentTranscriptLines: [], isPaused: false)
        XCTAssertEqual(backend.ending, ["orphan"])
        XCTAssertEqual(backend.updated, ["new"])
    }

    func testRepeatedAppearanceDoesNotRepeatStartupCleanup() async throws {
        let activity = ActivitySpy()
        let fixture = try await makeFixture(activity: activity)
        await fixture.recorder.onAppear()
        await fixture.recorder.onAppear()
        XCTAssertEqual(activity.cleanups, 1)
        XCTAssertTrue(activity.ending.isEmpty)
        await fixture.recorder.toggleRecording()
        XCTAssertEqual(activity.ended, [fixture.meeting.id])
    }

    func testSessionStopWithoutCallbackStillSealsAudio() async throws {
        let (services, engine) = try makeServices()
        let meeting = try await services.session.start(title: "Default stop")
        let stored = try await services.session.stop()
        XCTAssertEqual(stored.id, meeting.id)
        XCTAssertEqual(stored.state, .recorded)
        XCTAssertGreaterThan(stored.audioByteCount ?? 0, 0)
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testDrainPreventsReentrantStartUntilPublishCompletes() async throws {
        let (services, engine) = try makeServices()
        let first = try await services.session.start(title: "First")
        let entered = expectation(description: "capture callback entered")
        let gate = LifecycleGate(entered: entered)
        let drain = Task {
            try await services.session.drainCapture {
                await gate.wait()
            }
        }

        await fulfillment(of: [entered], timeout: 5)
        do {
            _ = try await services.session.start(title: "Rejected")
            XCTFail("start must be rejected while drain is suspended")
        } catch AudioCaptureError.alreadyRecording {
            // Expected: the first meeting remains isolated until drain returns.
        }
        let meetingsWhileDraining = try await MeetingRepository(services.database).fetchAll()
        XCTAssertEqual(meetingsWhileDraining.count, 1)

        await gate.open()
        let token = try await drain.value
        _ = try await services.session.publish(token, as: .recorded)
        let second = try await services.session.start(title: "Second")
        _ = try await services.session.stop()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(engine.stopCount, 2)
    }

    private func makeFixture(
        activity: ActivitySpy = ActivitySpy(),
        asrFinish: @escaping @Sendable () async throws -> Void = {},
        frameCount: Int = 1_600
    ) async throws -> Fixture {
        let (services, engine) = try makeServices(frameCount: frameCount)
        let meeting = try await services.session.start(title: "Lifecycle recording")
        try await UtteranceRepository(services.database).append(
            Utterance(
                meetingId: meeting.id, startMs: 0, endMs: 100, text: "Preserved text",
                originDeviceId: services.deviceId
            )
        )
        let transcription = TranscriptionModel(
            services: services, meetingId: meeting.id,
            asrFinish: asrFinish, diarizationFinish: {}
        )
        let recorder = RecorderModel(
            services: services, library: LibraryModel(services: services),
            activityController: activity, transcription: transcription
        )
        await recorder.recordingDidStart(meetingId: meeting.id)
        return Fixture(services: services, engine: engine, meeting: meeting, recorder: recorder)
    }

    private func makeServices(frameCount: Int = 1_600) throws -> (AppServices, LifecycleCaptureEngine) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
        let store = try AudioFileStore.standard(applicationSupport: root)
        let engine = LifecycleCaptureEngine(frameCount: frameCount)
        let services = try AppServices(database: .onDisk(directory: root), store: store, captureEngine: engine)
        let session = services.session
        let database = services.database
        addTeardownBlock {
            session.invalidate()
            try database.writer.close()
            try FileManager.default.removeItem(at: root)
        }
        return (services, engine)
    }

    private struct Fixture {
        let services: AppServices
        let engine: LifecycleCaptureEngine
        let meeting: Meeting
        let recorder: RecorderModel
    }
}

private actor LifecycleGate {
    private let entered: XCTestExpectation
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        entered.fulfill()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class ActivitySpy: RecordingActivityControlling {
    var cleanups = 0
    var ending: [String] = []
    var ended: [String] = []
    let endGate: LifecycleGate?

    init(endGate: LifecycleGate? = nil) { self.endGate = endGate }
    func cleanupOrphans() async { cleanups += 1 }
    func start(meetingId: String) async {}
    func update(meetingId: String, elapsed: TimeInterval, recentTranscriptLines: [String], isPaused: Bool) async {}
    func end(meetingId: String) async {
        ending.append(meetingId)
        await endGate?.wait()
        ended.append(meetingId)
    }
}

@MainActor
private final class ActivityBackend {
    var requested: [String] = []
    var ending: [String] = []
    var updated: [String] = []
    var existingIDs: [String] = []
    var endGates: [String: LifecycleGate] = [:]

    func controller() -> RecordingActivityController {
        RecordingActivityController(
            existingActivities: { self.existingIDs.map { self.handle($0) } },
            requestActivity: { id in
                self.requested.append(id)
                return self.handle(id)
            },
            isAuthorized: { true }
        )
    }

    private func handle(_ id: String) -> RecordingActivityHandle {
        RecordingActivityHandle(
            id: "activity-\(id)", meetingId: id,
            update: { _ in self.updated.append(id) },
            end: {
                self.ending.append(id)
                await self.endGates[id]?.wait()
            }
        )
    }
}

private final class LifecycleCaptureEngine: AudioCaptureControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var chunksContinuation: AsyncStream<AudioChunk>.Continuation?
    private var eventsContinuation: AsyncStream<AudioCaptureEvent>.Continuation?
    private var stops = 0
    var stopCount: Int { lock.withLock { stops } }
    private let frameCount: Int
    init(frameCount: Int = 1_600) { self.frameCount = frameCount }

    func chunks() -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in lock.withLock { chunksContinuation = continuation } }
    }
    func levels() -> AsyncStream<AudioLevel> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<AudioCaptureEvent> {
        AsyncStream { continuation in lock.withLock { eventsContinuation = continuation } }
    }
    func start() throws {
        lock.withLock {
            chunksContinuation?.yield(AudioChunk(
                index: 0, startFrame: 0, sampleRate: 16_000,
                samples: (0..<frameCount).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.1 },
                isFinal: false
            ))
        }
    }
    func pause() throws {}
    func resume() throws {}
    @discardableResult
    func stop() -> Int {
        lock.withLock {
            stops += 1
            chunksContinuation?.yield(AudioChunk(
                index: 1, startFrame: frameCount, sampleRate: 16_000, samples: [], isFinal: true
            ))
            eventsContinuation?.yield(.stopped(frameCount: frameCount))
        }
        return frameCount
    }
    func invalidate() {
        lock.withLock {
            chunksContinuation?.finish()
            eventsContinuation?.finish()
        }
    }
}
