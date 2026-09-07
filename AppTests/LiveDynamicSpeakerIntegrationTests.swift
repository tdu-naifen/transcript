import Foundation
import XCTest
@testable import FluidAudio
@testable import TranscriptCore
@testable import Transcript

@MainActor
final class LiveDynamicSpeakerIntegrationTests: XCTestCase {
    private func fixture() async throws -> (AppServices, Meeting) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build/live-app-fixtures/\(UUID().uuidString)")
        let database = try AppDatabase.inMemory()
        let store = try AudioFileStore.standard(applicationSupport: root)
        let services = try AppServices(database: database, store: store, captureEngine: LifecycleCaptureEngine())
        let meeting = Meeting(title: "App live", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        addTeardownBlock {
            try database.writer.close()
            try FileManager.default.removeItem(at: root)
        }
        return (services, meeting)
    }

    private func pipeline(_ services: AppServices, _ meeting: Meeting, gate: AppLiveGate? = nil) -> LiveDynamicSpeakers {
        LiveDynamicSpeakers(
            database: services.database, meetingID: meeting.id, deviceID: "test",
            admission: .init(acquire: { await RecordingAnalyzerSlots.shared.acquireIfAvailable() },
                             release: { await RecordingAnalyzerSlots.shared.release($0) }),
            prepareAssets: { .init(dynamic: URL(filePath: "."), camp: URL(filePath: "."), modelIdentifier: "app-CAM-fixture") },
            makeRuntime: { _ in AppLiveRuntime(gate: gate) })
    }

    func testActualTranscriptionModelStreamsDynamicEvidenceAndSharesPersistedRenameWithDetail() async throws {
        let (services, meeting) = try await fixture()
        let live = pipeline(services, meeting)
        let speech = AppLiveSpeech()
        let model = TranscriptionModel(services: services, makeTranscriber: { speech }, makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let speakers = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        let chunk = AudioChunk(index: 0, startFrame: 0, sampleRate: 16_000, samples: Array(repeating: 1, count: 160_000), isFinal: false)
        audio.continuation.yield(chunk)
        speakers.continuation.yield(chunk)
        try await eventually { model.lines.first.flatMap { model.speaker(for: $0) } != nil }
        let row = try XCTUnwrap(model.lines.first)
        let person = try XCTUnwrap(model.speaker(for: row))
        XCTAssertTrue(model.diarizationSegments.isEmpty, "Production is not using the four-slot diagnostic timeline.")
        XCTAssertTrue(model.speakersByIndex.isEmpty)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        await detail.load()
        XCTAssertEqual(detail.participants.map(\.id), [person.id])
        try await SpeakerRepository(services.database).rename(id: person.id, displayName: "Chosen person", deviceId: "manual")
        try await model.refreshSpeakerProjection()
        await detail.load()
        XCTAssertEqual(model.speaker(for: row)?.resolvedName, "Chosen person")
        XCTAssertEqual(detail.participants.first?.resolvedName, "Chosen person")
        audio.continuation.finish()
        speakers.continuation.finish()
        try await model.finish()
        await live.waitForIdle()
        let held = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(held, 0)
    }

    func testFinishDoesNotWaitForHeldNativeWorkAndNewCaptureCanPrepare() async throws {
        let (services, meeting) = try await fixture()
        let gate = AppLiveGate()
        let live = pipeline(services, meeting, gate: gate)
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() }, makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let speakers = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        speakers.continuation.yield(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                          samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await gate.waitForEntry()
        audio.continuation.finish()
        speakers.continuation.finish()
        let finished = Task { try await model.finish() }
        try await eventually { model.status == .idle }
        try await finished.value
        let held = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(held, 1, "Only physically active optional native work retains its permit.")
        let next = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() }, makeLiveSpeakers: { _ in nil })
        try await next.prepare()
        XCTAssertEqual(next.status, .preparing)
        await next.discard()
        await gate.release()
        await live.waitForIdle()
        let identities = try await SpeakerRepository(services.database).fetchAll()
        XCTAssertTrue(identities.isEmpty)
        let after = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(after, 0)
    }

    func testLocalizedFailuresAreOptionalAndInjectedServicesNeverDownloadLiveModels() async throws {
        let (services, meeting) = try await fixture()
        XCTAssertNil(services.makeLiveSpeakers(meetingID: meeting.id))
        let model = TranscriptionModel(services: services, meetingId: meeting.id, asrFinish: {}, diarizationFinish: {})
        for state in [LiveSpeakerStatus.modelsUnavailable, .processingFailed, .storageFailed, .busy, .paused] {
            await model.apply(state, meetingId: meeting.id)
            XCTAssertEqual(model.speakerWarning, LiveSpeakerText.warning(state))
            XCTAssertFalse(model.isIdentifyingSpeakers)
            XCTAssertNil(model.processingIssue)
        }
        await model.apply(LiveSpeakerStatus.identifying, meetingId: "another-meeting")
        XCTAssertEqual(model.speakerWarning, LiveSpeakerText.warning(.paused))
        await model.apply(LiveSpeakerStatus.identifying, meetingId: meeting.id)
        XCTAssertTrue(model.isIdentifyingSpeakers)
        await model.discard()
    }

    func testLateFinalASRAfterStopReadsAcceptedEvidenceNotCancelledInference() async throws {
        let (services, meeting) = try await fixture()
        let live = pipeline(services, meeting)
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech(finalizeOnFinish: true) },
                                       makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let speakers = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        let chunk = AudioChunk(index: 0, startFrame: 0, sampleRate: 16_000, samples: Array(repeating: 1, count: 160_000), isFinal: false)
        audio.continuation.yield(chunk)
        speakers.continuation.yield(chunk)
        let deadline = ContinuousClock.now + .seconds(5)
        while await live.metrics().processed == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processed = await live.metrics().processed
        XCTAssertEqual(processed, 1)
        XCTAssertTrue(model.lines.isEmpty)
        model.setLanguageSwitchingAllowed(false)
        try await services.database.writer.write {
            try $0.execute(sql: "UPDATE meeting SET state = 'recorded' WHERE id = ?", arguments: [meeting.id])
        }
        audio.continuation.finish()
        speakers.continuation.finish()
        try await model.finish()
        await live.waitForIdle()
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].speakerId)
    }

    private func eventually(_ predicate: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}

private actor AppLiveGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private actor AppLiveRuntime: LiveSpeakerInferring {
    let gate: AppLiveGate?
    init(gate: AppLiveGate?) { self.gate = gate }
    func extract(_ samples: [Float]) async -> CompletedWindowEvidence {
        if let gate { await gate.hold() }
        return CompletedWindowEvidence(
            segmentation: .init(
                logProbs: [Array(repeating: [-10, 0, -10, -10, -10, -10, -10], count: 589)],
                speakerWeights: [Array(repeating: [1, 0, 0], count: 589)], numChunks: 1, numFrames: 589,
                numSpeakers: 3, chunkOffsets: [0], frameDuration: 10.0 / 589),
            embeddings: [.init(
                chunkIndex: 0, speakerIndex: 0, startFrame: 0, endFrame: 588,
                frameWeights: Array(repeating: 1, count: 589), startTime: 0, endTime: 10,
                embedding256: [1] + Array(repeating: 0, count: 255), rho128: [1] + Array(repeating: 0, count: 127))],
            configuration: EvidenceAdapter.configuration())
    }
    func cluster(_ rows: [CompletedWindowEvidence.Row]) -> EvidenceCohortResult {
        .init(runID: UUID(), rowIDs: rows.map(\.id), assignments: Array(repeating: 0, count: rows.count))
    }
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) -> [Float] {
        [1] + Array(repeating: 0, count: 191)
    }
    func close() {}
}

private actor AppLiveSpeech: AppleTranscribing {
    let finalizeOnFinish: Bool
    init(finalizeOnFinish: Bool = false) { self.finalizeOnFinish = finalizeOnFinish }
    private var task: Task<Void, Never>?
    private let output = AsyncStream<ASRTranscriptEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
    func prepare(locale: Locale) {}
    func events() -> AsyncStream<ASRTranscriptEvent> { output.stream }
    func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {
        task = Task {
            var delayed: ASRSegment?
            output.continuation.yield(.ready(.init(language: .locale("en-US"), loadSeconds: 0)))
            for await chunk in chunks {
                let segment = ASRSegment(id: "\(meetingID)-\(chunk.index)", text: "Recorded sentence",
                                         startMs: chunk.startMs, endMs: chunk.startMs + 1_000,
                                         localeIdentifier: "en-US", isFinal: true)
                if finalizeOnFinish { delayed = segment; continue }
                do { try await services.append(segment); output.continuation.yield(.segment(segment)) }
                catch { output.continuation.yield(.failed("Fixture persistence failed")) }
            }
            if let delayed {
                do { try await services.append(delayed); output.continuation.yield(.segment(delayed)) }
                catch { output.continuation.yield(.failed("Fixture persistence failed")) }
            }
            output.continuation.yield(.finished)
            output.continuation.finish()
        }
    }
    func finishAndWait() async { await task?.value }
    func cancelAndWait() async { task?.cancel(); output.continuation.finish(); await task?.value }
}
