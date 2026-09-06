import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class SpeakerAnalysisServiceTests: XCTestCase {
    func testEnqueueDuringEmptyQueueReadCannotLoseWorkerWakeup() async throws {
        let db = try AppDatabase.inMemory()
        let services = try AppServices(database: db)
        let meeting = Meeting(title: "Wakeup", startedAt: Date(), audioFileName: "test.m4a", state: .recorded, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let entered = expectation(description: "Empty queue snapshot read")
        let lookup = PendingLookupProbe(jobs: SpeakerAnalysisRepository(db), entered: entered)
        let engine = AnalysisProbe(database: db)
        await engine.allowSuccess()
        let service = SpeakerAnalysisService(
            servicesDatabase: db, deviceID: "test", store: services.store,
            downloader: services.modelDownloader, enabled: true, engine: engine,
            nextPending: { try await lookup.next() }, isActive: true
        )
        service.resume()
        await fulfillment(of: [entered], timeout: 2)
        await service.enqueue(meeting)
        await lookup.release()
        await service.waitForIdle()
        XCTAssertEqual(service.states[meeting.id], .complete)
        let runs = await engine.runs
        XCTAssertEqual(runs, 1)
    }

    func testSavedMeetingIsQueuedOnceAndFailureCanBeRetriedWithoutLosingAudioMetadata() async throws {
        let db = try AppDatabase.inMemory()
        let services = try AppServices(database: db)
        let meeting = Meeting(title: "Persistent audio", startedAt: Date(), audioFileName: "test.m4a", state: .recorded, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let engine = AnalysisProbe(database: db)
        let service = SpeakerAnalysisService(
            servicesDatabase: db, deviceID: "test", store: services.store,
            downloader: services.modelDownloader, enabled: true, engine: engine, isActive: true
        )
        await service.enqueue(meeting)
        await service.waitForIdle()
        guard case .failed = service.states[meeting.id] else { return XCTFail("The user must see analysis failure") }
        let afterFailure = try await MeetingRepository(db).fetch(id: meeting.id)
        XCTAssertEqual(afterFailure?.audioFileName, "test.m4a")
        await engine.allowSuccess()
        await service.enqueue(meeting, retry: true)
        await service.waitForIdle()
        XCTAssertEqual(service.states[meeting.id], .complete)
        XCTAssertEqual(service.revision, 1)
        await service.enqueue(meeting)
        await service.waitForIdle()
        let runs = await engine.runs
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(service.revision, 1)
    }

    private actor PendingLookupProbe {
        let jobs: SpeakerAnalysisRepository
        let entered: XCTestExpectation
        private var first = true
        private var continuation: CheckedContinuation<Void, Never>?
        init(jobs: SpeakerAnalysisRepository, entered: XCTestExpectation) { self.jobs = jobs; self.entered = entered }
        func next() async throws -> String? {
            let value = try await jobs.nextPending()
            if first {
                first = false
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    entered.fulfill()
                }
            }
            return value
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testFixtureServicesNeverStartAutomaticModelDownloads() async throws {
        let db = try AppDatabase.inMemory()
        let services = try AppServices(database: db)
        let meeting = Meeting(title: "Fixture", startedAt: Date(), audioFileName: "fixture.m4a", state: .recorded, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        await services.speakerAnalysis.enqueue(meeting)
        let next = try await SpeakerAnalysisRepository(db).nextPending()
        XCTAssertNil(next)
    }

    func testInactiveJobsStayDurableAndResumeOnlyAfterCancellationDrains() async throws {
        let db = try AppDatabase.inMemory()
        let services = try AppServices(database: db)
        let meeting = Meeting(title: "Background", startedAt: Date(), audioFileName: "test.m4a", state: .recorded, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let started = expectation(description: "Foreground analysis started")
        let engine = CancellationAnalysisProbe(jobs: SpeakerAnalysisRepository(db), started: started)
        let service = SpeakerAnalysisService(
            servicesDatabase: db, deviceID: "test", store: services.store,
            downloader: services.modelDownloader, enabled: true, engine: engine, isActive: false
        )
        await service.enqueue(meeting)
        await service.waitForIdle()
        let initialRuns = await engine.runs
        XCTAssertEqual(initialRuns, 0)
        let pending = try await SpeakerAnalysisRepository(db).state(meetingID: meeting.id)
        XCTAssertEqual(pending, "pending")
        service.setActive(true)
        await fulfillment(of: [started], timeout: 2)
        service.setActive(false)
        await service.waitForIdle()
        let cancelledState = try await SpeakerAnalysisRepository(db).state(meetingID: meeting.id)
        XCTAssertEqual(cancelledState, "pending")
        XCTAssertNil(service.errorMessage)
        service.setActive(true)
        await service.waitForIdle()
        let runs = await engine.runs
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(service.states[meeting.id], .complete)
    }

    private actor CancellationAnalysisProbe: SpeakerAnalyzing {
        let jobs: SpeakerAnalysisRepository
        let started: XCTestExpectation
        var runs = 0
        init(jobs: SpeakerAnalysisRepository, started: XCTestExpectation) { self.jobs = jobs; self.started = started }
        func run(meetingID: String, audioURL: URL, progress: @escaping @Sendable (MeetingReprocessingStage) async -> Void) async throws {
            runs += 1
            if runs == 1 {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
            }
            try await jobs.setState(meetingID: meetingID, state: "complete")
        }
    }
}

private actor AnalysisProbe: SpeakerAnalyzing {
    let database: AppDatabase
    private var fails = true
    private(set) var runs = 0
    init(database: AppDatabase) { self.database = database }
    func allowSuccess() { fails = false }
    func run(meetingID: String, audioURL: URL, progress: @escaping @Sendable (MeetingReprocessingStage) async -> Void) async throws {
        runs += 1
        if fails { throw CocoaError(.fileReadCorruptFile) }
        await progress(.identifyingSpeakers)
        try await SpeakerAnalysisRepository(database).setState(meetingID: meetingID, state: "complete")
    }
}
