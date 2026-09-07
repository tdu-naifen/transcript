import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

enum MacProcessingTestFixtures {
    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mac-processing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func asr(in root: URL) throws -> ASRModelBundle {
        let directory = root.appendingPathComponent("fixture-model")
        for name in ["encoder", "decoder", "joint", "decoder_joint"] {
            let compiled = directory.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data("fixture only, never inference".utf8).write(to: compiled.appendingPathComponent("coremldata.bin"))
        }
        for name in ["metadata.json", "tokenizer.json"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        return ASRModelBundle(variant: .multilingual2240ms, directory: directory)
    }

    static func context(in root: URL, speakerCount: Int = 0) async throws -> (MacLibraryContext, Meeting) {
        let database = try AppDatabase.inMemory()
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let files = AudioFileStore(directory: audio)
        let meeting = Meeting(title: "Fixture meeting", startedAt: Date(), durationMs: 1_000,
                              audioFileName: "fixture.m4a", state: .recorded, originDeviceId: "iphone")
        try Data("synthetic input for fake runner".utf8).write(to: files.url(forFileName: "fixture.m4a"))
        try await database.writer.write { db in
            try meeting.insert(db)
            for index in 0..<speakerCount {
                let speaker = Speaker(displayName: "Person \(index)", anonymousName: "Speaker \(index)",
                                      originDeviceId: "iphone")
                try speaker.insert(db)
                try MeetingSpeaker(meetingId: meeting.id, speakerId: speaker.id, displayIndex: index + 1,
                                   originDeviceId: "iphone").insert(db)
            }
            try Utterance(meetingId: meeting.id, startMs: 0, endMs: 900, text: "Original edited text",
                          originDeviceId: "iphone").insert(db)
        }
        return (MacLibraryContext(database: database, directory: root, audioFiles: files, deviceID: "mac"), meeting)
    }

    static func snapshot(_ context: MacLibraryContext, meetingID: String) async throws -> MacTranscriptSnapshot {
        try await context.database.reader.read { db in
            try MacTranscriptSnapshot.read(db, meetingID: meetingID)
        }
    }
}

private actor FixtureASRRunner: MacProcessingRunning {
    enum Outcome: Sendable { case success, failure, waitForCancellation, empty }
    let outcome: Outcome
    private(set) var calls = 0
    init(_ outcome: Outcome = .success) { self.outcome = outcome }

    func run(meetingID: String, audioURL: URL, deviceID: String, models: [MacFrozenModel], language: String,
             progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> [ASRSegment] {
        calls += 1
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.adapter, .nemotronMultilingual)
        await progress(.init(stage: .transcribing, fractionCompleted: 0.5))
        switch outcome {
        case .failure: throw MacProcessingError.transcriptionFailed("Fixture failure")
        case .waitForCancellation: try await Task.sleep(for: .seconds(60))
        case .empty: return []
        case .success: break
        }
        return [ASRSegment(id: "result", text: "New ASR text", startMs: 0, endMs: 800,
                           localeIdentifier: "en-US", isFinal: true)]
    }
}

@MainActor
final class MacProcessingTests: XCTestCase {
    func testASROnlyVersionPreservesFortySpeakersAndEntireLiveTranscript() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root, speakerCount: 40)
        let before = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        let model = MacProcessingModel(runner: FixtureASRRunner())
        model.configure(context: context)
        try model.catalog.useManagedASR(MacProcessingTestFixtures.asr(in: root))
        XCTAssertTrue(model.canRun)
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.state, .readyForReview)
        XCTAssertEqual(job.previous, before)
        XCTAssertEqual(job.proposal?.utterances.map(\.text), ["New ASR text"])
        XCTAssertTrue(try XCTUnwrap(job.proposal).utterances.allSatisfy { $0.speakerId == nil })
        XCTAssertEqual(job.proposal?.links.count, 0)
        XCTAssertEqual(job.models.map(\.category), [.asr])
        XCTAssertFalse(job.enrollsGlobalVoiceprints)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try MacProcessingStore(libraryDirectory: root).audio(job.id).path))
        model.keepLocalVersion(jobID: job.id)
        XCTAssertEqual(model.jobs.first?.state, .savedLocally)
        let after = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.links.count, 40)
        XCTAssertNil(after.meeting.syncedToMacAt)
        XCTAssertNil(after.meeting.audioVerifiedOnMacAt)
        let reopened = MacProcessingModel(runner: FixtureASRRunner())
        reopened.configure(context: context)
        XCTAssertEqual(reopened.jobs.first?.state, .savedLocally)
        XCTAssertEqual(reopened.jobs.first?.proposal, job.proposal)
    }

    func testFailedAndEmptyRunsNeverReplaceLibrary() async throws {
        for outcome in [FixtureASRRunner.Outcome.failure, .empty] {
            let root = try MacProcessingTestFixtures.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
            let before = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
            let model = MacProcessingModel(runner: FixtureASRRunner(outcome))
            model.configure(context: context)
            try model.catalog.useManagedASR(MacProcessingTestFixtures.asr(in: root))
            model.start(meetingID: meeting.id)
            await model.waitForCurrentJob()
            XCTAssertEqual(model.jobs.first?.state, .failed)
            XCTAssertNil(model.jobs.first?.proposal)
            XCTAssertNotNil(model.errorMessage)
            let after = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
            XCTAssertEqual(after, before)
        }
    }

    func testCancellationDrainsAndRetryCreatesIndependentVersion() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let before = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        let runner = FixtureASRRunner(.waitForCancellation)
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try model.catalog.useManagedASR(MacProcessingTestFixtures.asr(in: root))
        model.start(meetingID: meeting.id)
        let firstID = try XCTUnwrap(model.activeJobID)
        for _ in 0..<1_000 {
            if await runner.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
        model.cancel()
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.first?.state, .cancelled)
        XCTAssertFalse(model.isBusy)
        model.retry(jobID: firstID)
        XCTAssertNotEqual(model.activeJobID, firstID)
        model.cancel()
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.count, 2)
        let after = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(after, before)
    }

    func testUnsupportedASRDoesNotFallbackOrCreateJob() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        var custom = MacModelCard.builtins[0]
        custom.id = "custom"
        try model.catalog.add(custom)
        try model.catalog.select(custom.id, category: .asr)
        model.start(meetingID: meeting.id)
        XCTAssertFalse(model.canRun)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    func testFrozenModelAndAudioChangesAreRejectedBeforeRunnerExecutes() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let bundle = try MacProcessingTestFixtures.asr(in: root)
        var card = MacModelCard.builtins[0]
        card.localPath = bundle.directory.path
        let store = try MacProcessingStore(libraryDirectory: root)
        let runner = FixtureASRRunner()
        let worker = MacProcessingWorker(runner: runner)
        let job = MacProcessingJob(id: UUID(), meetingID: meeting.id, createdAt: Date(),
                                   state: .preparing, stage: "preparing", progress: 0, language: "auto", models: [])
        try store.save(job)
        let frozen = try await worker.prepare(job: job, cards: [card], context: context, store: store)
        let metadata = bundle.directory.appendingPathComponent("metadata.json")
        try Data(#"{"changed":true}"#.utf8).write(to: metadata)
        do {
            _ = try await worker.process(job: frozen, context: context, store: store, progress: { _ in })
            XCTFail("Changed model must not execute")
        } catch MacProcessingError.modelChanged { }
        try Data("{}".utf8).write(to: metadata)
        try Data("changed audio".utf8).write(to: store.audio(job.id))
        do {
            _ = try await worker.process(job: frozen, context: context, store: store, progress: { _ in })
            XCTFail("Changed frozen audio must not execute")
        } catch MacProcessingError.invalidManifest { }
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    func testReviewKeepsConcurrentLibraryEditsAndNeverSupersedesOtherVersions() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let model = MacProcessingModel(runner: FixtureASRRunner())
        model.configure(context: context)
        try model.catalog.useManagedASR(MacProcessingTestFixtures.asr(in: root))
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        let first = try XCTUnwrap(model.jobs.first)
        try await context.database.writer.write { db in
            try db.execute(sql: "UPDATE utterance SET text = ? WHERE meetingId = ?",
                           arguments: ["Concurrent user edit", meeting.id])
        }
        let edited = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        model.keepLocalVersion(jobID: first.id)
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs.first { $0.id == first.id }?.state, .savedLocally)
        XCTAssertEqual(model.jobs.first?.previous, edited)
        let after = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(after, edited)
    }

    func testInProgressRecordingAndMismatchedOriginalAudioNeverExecute() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try model.catalog.useManagedASR(MacProcessingTestFixtures.asr(in: root))
        try await context.database.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET state = 'recording' WHERE id = ?", arguments: [meeting.id])
        }
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.first?.state, .failed)
        try await context.database.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET state = 'recorded', audioSHA256 = ? WHERE id = ?",
                           arguments: [String(repeating: "0", count: 64), meeting.id])
        }
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.first?.state, .failed)
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    func testInterruptedAndLegacyJobsRequireRetryWithoutPublishing() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacProcessingStore(libraryDirectory: root)
        let running = MacProcessingJob(id: UUID(), meetingID: "fixture", createdAt: Date(),
                                      state: .running, stage: "transcribing", progress: 0.2, language: "auto", models: [])
        try store.save(running)
        try Data("interrupted frozen input".utf8).write(to: store.audio(running.id))
        var legacy = running
        legacy = MacProcessingJob(id: UUID(), meetingID: "fixture", createdAt: Date(),
                                  state: .published, stage: "legacy", progress: 1, language: "auto", models: [])
        legacy.version = 1
        try store.save(legacy)
        let jobs = try store.load()
        XCTAssertEqual(jobs.first { $0.id == running.id }?.state, .needsRetry)
        XCTAssertEqual(jobs.first { $0.id == legacy.id }?.state, .stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audio(running.id).path))
    }

    func testModelHashDetectsChangesAndRejectsSymbolicLinks() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try MacProcessingTestFixtures.asr(in: root)
        let before = try MacProcessingWorker.hashModel(at: bundle.directory)
        try Data(#"{"changed":true}"#.utf8).write(to: bundle.directory.appendingPathComponent("metadata.json"))
        XCTAssertNotEqual(before, try MacProcessingWorker.hashModel(at: bundle.directory))
        let link = root.appendingPathComponent("linked-model")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle.directory)
        XCTAssertThrowsError(try MacProcessingWorker.hashModel(at: link))
        try FileManager.default.createSymbolicLink(at: bundle.directory.appendingPathComponent("linked-file"),
                                                  withDestinationURL: bundle.directory.appendingPathComponent("metadata.json"))
        XCTAssertThrowsError(try MacProcessingWorker.hashModel(at: bundle.directory))
    }

    func testMissingMeetingFailsWithoutRecreation() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        let model = MacProcessingModel(runner: FixtureASRRunner())
        model.configure(context: context)
        try model.catalog.useManagedASR(MacProcessingTestFixtures.asr(in: root))
        model.start(meetingID: "missing")
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.first?.state, .failed)
        let missing = try await MeetingRepository(context.database).fetch(id: "missing")
        XCTAssertNil(missing)
    }
}
