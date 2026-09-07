import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

enum MacProcessingTestFixtures {
    @MainActor
    static func installModels(_ bundle: ASRModelBundle, catalog: MacModelCatalog) throws {
        try catalog.useManagedASR(bundle)
        let root = bundle.directory.deletingLastPathComponent()
        for category in [MacModelCategory.diarization, .speakerEmbedding] {
            let directory = root.appendingPathComponent("fixture-\(category.rawValue)")
            let names = category == .diarization ? [""] : ["CamPlusPreprocessor.mlmodelc", "CamPlusPlus.mlmodelc"]
            for name in names {
                let compiled = name.isEmpty ? directory : directory.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
                try Data("fixture only, never inference".utf8).write(to: compiled.appendingPathComponent("coremldata.bin"))
            }
            try catalog.useManagedModel(category: category, at: directory)
        }
    }

    static func root() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRANSCRIPT_TEST_ROOT"]
                       ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
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
        let bytes = Data("synthetic input for fake runner".utf8)
        try bytes.write(to: files.url(forFileName: "fixture.m4a"))
        let digest = try IncrementalSHA256.hashFile(at: files.url(forFileName: "fixture.m4a"))
        let meeting = Meeting(title: "Fixture meeting", startedAt: Date(), durationMs: 1_000,
                              audioFileName: "fixture.m4a", audioSHA256: digest.sha256,
                              audioByteCount: digest.byteCount, state: .recorded, originDeviceId: "iphone")
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
    let beforeResult: (@Sendable () async throws -> Void)?
    private(set) var calls = 0
    init(_ outcome: Outcome = .success, beforeResult: (@Sendable () async throws -> Void)? = nil) {
        self.outcome = outcome
        self.beforeResult = beforeResult
    }

    func run(meetingID: String, audioURL: URL, deviceID: String, models: [MacFrozenModel], language: String,
             progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> [ASRSegment] {
        calls += 1
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models.first?.adapter, .nemotronMultilingual)
        await progress(.init(stage: .transcribing, fractionCompleted: 0.5))
        switch outcome {
        case .failure: throw MacProcessingError.transcriptionFailed("Fixture failure")
        case .waitForCancellation: try await Task.sleep(for: .seconds(60))
        case .empty: return []
        case .success: break
        }
        try await beforeResult?()
        return [ASRSegment(id: "result", text: "New ASR text", startMs: 0, endMs: 800,
                           localeIdentifier: "en-US", isFinal: true)]
    }
}

private actor DeletionDrainRunner: MacProcessingRunning {
    private(set) var started = false
    private(set) var cancellationObserved = false
    private var drain: CheckedContinuation<Void, Never>?
    private var released = false

    func release() {
        released = true
        drain?.resume()
        drain = nil
    }

    func run(meetingID: String, audioURL: URL, deviceID: String, models: [MacFrozenModel], language: String,
             progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> [ASRSegment] {
        started = true
        do { try await Task.sleep(for: .seconds(60)) } catch { cancellationObserved = true }
        if !released { await withCheckedContinuation { drain = $0 } }
        await progress(.init(stage: .transcribing, fractionCompleted: 0.9))
        return [ASRSegment(id: "late-result", text: "Must not survive deletion", startMs: 0, endMs: 800,
                           localeIdentifier: "en-US", isFinal: true)]
    }
}

@MainActor
private extension MacProcessingModel {
    func enqueueImportedMeeting(meetingID: String, inputRevision: String) async {
        await enqueueImportedMeeting(
            meetingID: meetingID, inputRevision: inputRevision,
            provenance: .init(peerID: "authorized-fixture-peer", operationID: "authorized-fixture-import"))
    }
}

@MainActor
final class MacProcessingTests: XCTestCase {
    func testManualProcessingDefaultsToFencedLibraryPublication() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let model = MacProcessingModel(runner: FixtureASRRunner())
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.destination, .library)
        XCTAssertEqual(job.state, .published, job.error ?? "")
        XCTAssertNotNil(job.processingInput)
        XCTAssertNotNil(job.outputTranscriptRevision)
        let saved = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(saved.utterances.map(\.text), ["New ASR text"])
    }

    func testMissingSpeakerModelsWaitDurablyAndConfigurationTracksAllModels() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        let configuredID = model.configurationID
        let missing = try XCTUnwrap(model.catalog.selected(.speakerEmbedding)?.resolvedURL())
        try FileManager.default.removeItem(at: missing)
        XCTAssertFalse(model.canRun)
        model.start(meetingID: meeting.id, destination: .library)
        XCTAssertEqual(model.jobs.first?.state, .waitingForConfiguration)
        XCTAssertNil(model.activeJobID)
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
        model.cancel(jobID: try XCTUnwrap(model.jobs.first?.id))
        let reopened = MacProcessingModel(runner: FixtureASRRunner())
        reopened.configure(context: context)
        XCTAssertEqual(reopened.jobs.first?.state, .cancelled)
        let alternate = root.appendingPathComponent("alternate-embedding")
        for name in ["CamPlusPreprocessor.mlmodelc", "CamPlusPlus.mlmodelc"] {
            let folder = alternate.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: folder.appendingPathComponent("coremldata.bin"))
        }
        try model.catalog.locate(alternate, cardID: "campplus-coreml")
        XCTAssertNotEqual(configuredID, model.configurationID)
    }

    // Hypothesis: deletion removes only owned job artifacts, including after an offline restart.
    func testStartupRemovesDeletedMeetingJobFoldersButPreservesOtherOwners() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root, speakerCount: 1)
        let other = Meeting(title: "Keep", startedAt: Date(), originDeviceId: "mac")
        try await context.database.writer.write { db in try other.insert(db) }
        let store = try MacProcessingStore(libraryDirectory: root)
        let snapshot = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        let deleted = MacProcessingJob(
            id: UUID(), meetingID: meeting.id, createdAt: Date(), state: .readyForReview,
            stage: "Ready", progress: 1, language: "auto", models: [], previous: snapshot, proposal: snapshot)
        let retained = MacProcessingJob(
            id: UUID(), meetingID: other.id, createdAt: Date(), state: .savedLocally,
            stage: "Keep", progress: 1, language: "auto", models: [])
        try store.save(deleted)
        try store.save(retained)
        try Data("private frozen audio".utf8).write(to: store.audio(deleted.id))
        try Data("private proposal".utf8).write(to: store.folder(deleted.id).appendingPathComponent("proposal.json"))
        let retainedBytes = try Data(contentsOf: store.folder(retained.id).appendingPathComponent("job.json"))
        let bundle = try MacProcessingTestFixtures.asr(in: root)
        let modelHash = try MacProcessingWorker.hashModel(at: bundle.directory)
        try await MeetingRepository(context.database).delete(id: meeting.id)

        let reopened = MacProcessingModel(runner: FixtureASRRunner())
        reopened.configure(context: context)
        XCTAssertTrue(reopened.isConfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(deleted.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audio(deleted.id).path))
        XCTAssertEqual(reopened.jobs.map(\.id), [retained.id])
        XCTAssertEqual(try Data(contentsOf: store.folder(retained.id).appendingPathComponent("job.json")), retainedBytes)
        XCTAssertEqual(try MacProcessingWorker.hashModel(at: bundle.directory), modelHash)
        let speakerCount = try await context.database.reader.read { db in try Speaker.fetchCount(db) }
        XCTAssertEqual(speakerCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try context.audioFiles.url(forFileName: "fixture.m4a").path))
        let again = MacProcessingModel(runner: FixtureASRRunner())
        again.configure(context: context)
        XCTAssertEqual(again.jobs.map(\.id), [retained.id])
    }

    // Hypothesis: a committed remote tombstone cancels work, but deletion waits for the runner to drain.
    func testRemoteDeletionDrainsActiveRunnerAndRejectsLateProgressAndResults() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = DeletionDrainRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        model.start(meetingID: meeting.id)
        for _ in 0..<400 {
            if await runner.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await runner.started
        XCTAssertTrue(started)
        let jobID = try XCTUnwrap(model.activeJobID)
        let store = try MacProcessingStore(libraryDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audio(jobID).path))

        let sourceDB = try AppDatabase.inMemory()
        let source = AutomaticSyncRepository(sourceDB)
        try await source.configure(peerID: "mac", enabled: true)
        try await context.database.writer.write { db in
            // Ensure observation also handles a populated job while other metadata is changing.
            try db.execute(sql: "UPDATE meeting SET title = 'Before deletion' WHERE id = ?", arguments: [meeting.id])
        }
        try await sourceDB.writer.write { db in try meeting.insert(db) }
        try await MeetingRepository(sourceDB).delete(id: meeting.id)
        let tombstones = try await source.pending(peerID: "mac").filter { $0.entity == .meeting && $0.isDelete }
        XCTAssertFalse(tombstones.isEmpty)
        let target = AutomaticSyncRepository(context.database)
        try await target.configure(peerID: "iphone", enabled: true)
        try await target.apply(tombstones, from: "iphone")
        for _ in 0..<400 {
            if await runner.cancellationObserved { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = await runner.cancellationObserved
        XCTAssertTrue(cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audio(jobID).path),
                      "The runner still owns its frozen input until it finishes draining")
        await runner.release()
        if !cancelled { model.cancel() }
        await model.waitForCurrentJob()
        for _ in 0..<400 where FileManager.default.fileExists(atPath: store.folder(jobID).path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(jobID).path))
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertNil(model.activeJobID)
        let missing = try await MeetingRepository(context.database).fetch(id: meeting.id)
        XCTAssertNil(missing)
        let reopened = MacProcessingModel(runner: FixtureASRRunner())
        reopened.configure(context: context)
        XCTAssertTrue(reopened.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(jobID).path))
    }

    func testOrphanRemovalRejectsMismatchedOwnershipAndSymbolicLinks() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacProcessingStore(libraryDirectory: root)
        let job = MacProcessingJob(
            id: UUID(), meetingID: "deleted", createdAt: Date(), state: .savedLocally,
            stage: "Keep", progress: 1, language: "auto", models: [])
        let other = MacProcessingJob(
            id: job.id, meetingID: "other-meeting", createdAt: Date(), state: .savedLocally,
            stage: "Keep", progress: 1, language: "auto", models: [])
        try store.save(other)
        XCTAssertThrowsError(try store.remove(job))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(other.id).path))
        try store.remove(other)

        let outside = root.appendingPathComponent("not-processing")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let manifest = outside.appendingPathComponent("job.json")
        try JSONEncoder().encode(job).write(to: manifest)
        try FileManager.default.createSymbolicLink(at: store.folder(job.id), withDestinationURL: outside)
        XCTAssertThrowsError(try store.remove(job))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    // Hypothesis: a committed import is one durable request, not a side effect of rendering or reconnecting.
    func testImportedMeetingWaitsForConfigurationAndDeduplicatesAcrossRestart() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let model = MacProcessingModel(runner: FixtureASRRunner())
        model.configure(context: context)
        let missing = try MacProcessingTestFixtures.asr(in: root)
        try MacProcessingTestFixtures.installModels(missing, catalog: model.catalog)
        try FileManager.default.removeItem(at: missing.directory)
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.state, .waitingForConfiguration)
        XCTAssertNil(model.activeJobID)
        let reopened = MacProcessingModel(runner: FixtureASRRunner())
        reopened.configure(context: context)
        await reopened.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        XCTAssertEqual(reopened.jobs.count, 1)
        XCTAssertEqual(reopened.jobs.first?.state, .waitingForConfiguration)
        XCTAssertEqual(reopened.jobs.first?.automaticImport?.peerID, "authorized-fixture-peer")
        reopened.cancel(jobID: try XCTUnwrap(reopened.jobs.first?.id))
        await reopened.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        XCTAssertEqual(reopened.jobs.count, 1)
        XCTAssertEqual(reopened.jobs.first?.state, .cancelled)
    }

    func testManualProcessWithoutResourcesWaitsWithoutPretendingToRun() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        let bundle = try MacProcessingTestFixtures.asr(in: root)
        try MacProcessingTestFixtures.installModels(bundle, catalog: model.catalog)
        try FileManager.default.removeItem(at: bundle.directory)
        model.start(meetingID: meeting.id)
        model.start(meetingID: meeting.id)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.state, .waitingForConfiguration)
        XCTAssertNil(model.activeJobID)
        XCTAssertFalse(model.isBusy)
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    func testImportedMeetingProcessesOnceAndMetadataDoesNotEnqueueAgain() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        await model.waitForCurrentJob()
        try await context.database.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET title = ? WHERE id = ?", arguments: ["Renamed", meeting.id])
            try db.execute(sql: "UPDATE utterance SET text = ? WHERE meetingId = ?", arguments: ["Edited", meeting.id])
        }
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.state, .published)
        XCTAssertNotNil(model.jobs.first?.outputTranscriptRevision)
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
        try model.catalog.setLanguage("en-US")
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.count, 1, "Replaying the authorized import is not explicit reprocessing.")
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.count, 2)
    }

    func testWaitingImportResumesAfterSettingsAndFailureDoesNotAutoRetry() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner(.failure)
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        let missing = try MacProcessingTestFixtures.asr(in: root)
        try MacProcessingTestFixtures.installModels(missing, catalog: model.catalog)
        try FileManager.default.removeItem(at: missing.directory)
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        let id = try XCTUnwrap(model.jobs.first?.id)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        model.resumeQueuedJobs()
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.first?.id, id)
        XCTAssertEqual(model.jobs.first?.state, .failed)
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "audio-revision")
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.count, 1)
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
    }

    func testLegacyVerifiedCopyDoesNotAuthorizeAutomaticProcessing() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        XCTAssertTrue(model.jobs.isEmpty)
        let hash = try IncrementalSHA256.hashFile(at: context.audioFiles.url(forFileName: "fixture.m4a")).sha256
        try await context.database.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET audioSHA256 = ?, audioVerifiedOnMacAt = ? WHERE id = ?",
                           arguments: [hash, Date(), meeting.id])
        }
        let reopened = MacProcessingModel(runner: runner)
        reopened.configure(context: context)
        await reopened.waitForCurrentJob()
        XCTAssertTrue(reopened.jobs.isEmpty, "A legacy immutable copy receipt grants no automatic processing.")
        await reopened.enqueueImportedMeeting(
            meetingID: meeting.id, inputRevision: hash, provenance: .init(peerID: "", operationID: ""))
        XCTAssertTrue(reopened.jobs.isEmpty)
        try model.catalog.setLanguage("zh-CN")
        XCTAssertTrue(model.jobs.isEmpty)
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    func testInterruptedImportRequiresExplicitRetryAndRetainsDedupIdentity() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        let store = try MacProcessingStore(libraryDirectory: root)
        let job = MacProcessingJob(
            id: UUID(), meetingID: meeting.id, createdAt: Date(), state: .running,
            stage: "transcribing", progress: 0.5, language: "auto", models: [],
            inputRevision: "revision", configurationID: model.configurationID)
        try store.save(job)
        let reopened = MacProcessingModel(runner: runner)
        reopened.configure(context: context)
        await reopened.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: "revision")
        await reopened.waitForCurrentJob()
        XCTAssertEqual(reopened.jobs.count, 1)
        XCTAssertEqual(reopened.jobs.first?.state, .needsRetry)
        XCTAssertNil(reopened.activeJobID)
        XCTAssertEqual(try store.load().first?.state, .needsRetry)
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    // Hypothesis: publication commits real timed utterances and rejects edits made after input freeze.
    func testAutomaticPublicationWritesTranscriptAndRetainsNewerEdits() async throws {
        for editsDuringProcessing in [false, true] {
            let root = try MacProcessingTestFixtures.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
            let runner = FixtureASRRunner(beforeResult: {
                if editsDuringProcessing {
                    try await context.database.writer.write { db in
                        try db.execute(sql: "UPDATE utterance SET text = ? WHERE meetingId = ?",
                                       arguments: ["Newer user edit", meeting.id])
                    }
                }
            })
            let model = MacProcessingModel(runner: runner)
            model.configure(context: context)
            try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
            await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: try XCTUnwrap(meeting.audioSHA256))
            await model.waitForCurrentJob()
            let saved = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
            XCTAssertEqual(saved.utterances.map(\.text), [editsDuringProcessing ? "Newer user edit" : "New ASR text"])
            XCTAssertEqual(model.jobs.first?.state, editsDuringProcessing ? .stale : .published)
            XCTAssertEqual(saved.utterances.first?.startMs, 0)
            if !editsDuringProcessing { XCTAssertEqual(saved.utterances.first?.endMs, 800) }
        }
    }

    func testPublicationRecoveryIsIdempotentAndDoesNotRequireModelsOrRerunASR() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner()
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        let bundle = try MacProcessingTestFixtures.asr(in: root)
        try MacProcessingTestFixtures.installModels(bundle, catalog: model.catalog)
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: try XCTUnwrap(meeting.audioSHA256))
        await model.waitForCurrentJob()
        var job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.state, .published)
        let output = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        job.state = .publishing
        job.outputTranscriptRevision = nil
        job.publishedAt = nil
        try MacProcessingStore(libraryDirectory: root).save(job)
        try FileManager.default.removeItem(at: bundle.directory)
        let reopened = MacProcessingModel(runner: runner)
        reopened.configure(context: context)
        await reopened.waitForCurrentJob()
        XCTAssertEqual(reopened.jobs.first?.state, .published)
        XCTAssertEqual(reopened.jobs.first?.id, job.id)
        let recovered = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(recovered, output)
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
    }

    func testAutomaticPublicationPreservesNewerSpeakerAssignmentWithoutDiscardingASR() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let speaker = Speaker(displayName: "User assigned", anonymousName: "Speaker", originDeviceId: "iphone")
        let runner = FixtureASRRunner(beforeResult: {
            try await context.database.writer.write { db in
                try speaker.insert(db)
                try MeetingSpeaker(meetingId: meeting.id, speakerId: speaker.id,
                                   displayIndex: 1, originDeviceId: "iphone").insert(db)
                try db.execute(sql: "UPDATE utterance SET speakerId = ? WHERE meetingId = ?",
                               arguments: [speaker.id, meeting.id])
            }
        })
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: try XCTUnwrap(meeting.audioSHA256))
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.first?.state, .published)
        let saved = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(saved.utterances.first?.speakerId, speaker.id)
        XCTAssertEqual(saved.utterances.first?.text, "New ASR text")
    }

    func testAutomaticPublicationHonorsAudioPurgeAfterInputCapture() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let runner = FixtureASRRunner(beforeResult: {
            try await context.database.writer.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET audioVerifiedOnMacAt = ?, localAudioPurgedAt = ? WHERE id = ?",
                    arguments: [Date(), Date(), meeting.id]
                )
            }

        })
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        await model.enqueueImportedMeeting(meetingID: meeting.id, inputRevision: try XCTUnwrap(meeting.audioSHA256))
        await model.waitForCurrentJob()
        XCTAssertNotNil(model.jobs.first?.processingInput)
        XCTAssertEqual(model.jobs.first?.state, .stale, model.jobs.first?.error ?? "No failure detail")
        let saved = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(saved.utterances.first?.text, "Original edited text")
    }

    func testAutomaticPublicationPreservesNewerSpeakerClearWithoutDiscardingASR() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root, speakerCount: 1)
        try await context.database.writer.write { db in
            let speaker = try XCTUnwrap(Speaker.fetchOne(db))
            try db.execute(sql: "UPDATE utterance SET speakerId = ? WHERE meetingId = ?",
                           arguments: [speaker.id, meeting.id])
        }
        let runner = FixtureASRRunner(beforeResult: {
            try await context.database.writer.write { db in
                try db.execute(sql: "UPDATE utterance SET speakerId = NULL WHERE meetingId = ?",
                               arguments: [meeting.id])
            }
        })
        let model = MacProcessingModel(runner: runner)
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        model.start(meetingID: meeting.id)
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.first?.state, .published, model.jobs.first?.error ?? "")
        let saved = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertNil(saved.utterances.first?.speakerId)
        XCTAssertEqual(saved.utterances.first?.text, "New ASR text")
    }

    func testStartupReplayProcessesOnlyDurablyAdoptedAutomaticAudio() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        let remote = try AppDatabase.inMemory()
        let sender = AutomaticSyncRepository(remote)
        let receiver = AutomaticSyncRepository(context.database)
        try await sender.configure(peerID: "mac", enabled: true)
        try await receiver.configure(peerID: "authorized-iphone", enabled: true)
        let resourceID = try await sender.registerResource(.init(
            kind: .audio, meetingID: meeting.id, sha256: try XCTUnwrap(meeting.audioSHA256),
            byteCount: Int64(try XCTUnwrap(meeting.audioByteCount))))
        let operations = try await sender.pending(peerID: "mac")
        try await receiver.apply(operations, from: "authorized-iphone")
        let source = try context.audioFiles.url(forFileName: "fixture.m4a")
        let bytes = try Data(contentsOf: source)
        let transfer = AutomaticSyncResourceTransfer(context.database, directory: context.audioFiles.directory)
        let committedOffset = try await transfer.receive(
            .init(resourceID: resourceID, offset: 0, total: Int64(bytes.count), bytes: bytes),
            from: "authorized-iphone")
        XCTAssertEqual(committedOffset, Int64(bytes.count))
        let beforeAdoption = try await receiver.verifiedAudioImports()
        XCTAssertTrue(beforeAdoption.isEmpty)
        try await receiver.adoptAudioResource(id: resourceID)
        let imports = try await receiver.verifiedAudioImports()
        let imported = try XCTUnwrap(imports.first)
        let unauthorized = MacProcessingModel(runner: FixtureASRRunner())
        unauthorized.configure(context: context)
        await unauthorized.replayVerifiedImports()
        XCTAssertTrue(unauthorized.jobs.isEmpty, "A durable import still requires the trusted replay adapter.")
        let model = MacProcessingModel(runner: FixtureASRRunner())
        model.replayAutomaticImports = { [weak model] in
            for imported in try await receiver.verifiedAudioImports() {
                await model?.enqueueImportedMeeting(
                    meetingID: imported.meetingID, inputRevision: imported.audioSHA256,
                    provenance: .init(peerID: imported.peerID, operationID: imported.operationID))
            }
        }
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        for _ in 0..<400 where model.jobs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await model.waitForCurrentJob()
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.state, .published)
        XCTAssertEqual(model.jobs.first?.automaticImport?.operationID, imported.operationID)
        XCTAssertEqual(model.jobs.first?.automaticImport?.peerID, "authorized-iphone")
        await model.replayVerifiedImports()
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testASROnlyVersionPreservesFortySpeakersAndEntireLiveTranscript() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root, speakerCount: 40)
        let before = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        let model = MacProcessingModel(runner: FixtureASRRunner())
        model.configure(context: context)
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        XCTAssertTrue(model.canRun)
        model.start(meetingID: meeting.id, destination: .localVersion)
        await model.waitForCurrentJob()
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.state, .readyForReview)
        XCTAssertEqual(job.previous, before)
        XCTAssertEqual(job.proposal?.utterances.map(\.text), ["New ASR text"])
        XCTAssertTrue(try XCTUnwrap(job.proposal).utterances.allSatisfy { $0.speakerId == nil })
        XCTAssertEqual(job.proposal?.links.count, 0)
        XCTAssertEqual(job.models.map(\.category), MacModelCategory.allCases)
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
            try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
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
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
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
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        model.start(meetingID: meeting.id, destination: .localVersion)
        await model.waitForCurrentJob()
        let first = try XCTUnwrap(model.jobs.first)
        try await context.database.writer.write { db in
            try db.execute(sql: "UPDATE utterance SET text = ? WHERE meetingId = ?",
                           arguments: ["Concurrent user edit", meeting.id])
        }
        let edited = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        model.keepLocalVersion(jobID: first.id)
        model.start(meetingID: meeting.id, destination: .localVersion)
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
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
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
        try MacProcessingTestFixtures.installModels(MacProcessingTestFixtures.asr(in: root), catalog: model.catalog)
        model.start(meetingID: "missing")
        await model.waitForCurrentJob()
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        let missing = try await MeetingRepository(context.database).fetch(id: "missing")
        XCTAssertNil(missing)
    }
}
