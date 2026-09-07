import CoreML
import Foundation
import XCTest
@testable import FluidAudio
@testable import TranscriptCore

@MainActor
final class LiveSpeakerCPUConfigurationTests: XCTestCase {
    private func directories() throws -> (dynamic: URL, camp: URL) {
        let environment = ProcessInfo.processInfo.environment
        guard let dynamic = environment[DynamicSpeakerModelStore.overrideEnvironmentKey],
              let camp = environment[DiarizationModelStore.campPlusOverrideEnvironmentKey] else {
            throw XCTSkip("Pinned local dynamic and CAM bundles are required.")
        }
        return (URL(filePath: dynamic), URL(filePath: camp))
    }

    func testLiveDefaultLoadsDynamicWithoutGPUAndCAMOnCPU() async throws {
        let directories = try directories()
        let assets = try LiveSpeakerAssets(dynamic: directories.dynamic, camp: directories.camp,
                                          modelIdentifier: SpeakerAnalysisEngine.modelIdentifier(at: directories.camp))
        // false is the public live initializer's default, not a CPU-only test override.
        let runtime = try LiveSpeakerNativeRuntime(assets: assets, meetingID: "configuration-test", cpuOnly: false)
        let dynamic = await runtime.loadedDynamicComputeUnits
        XCTAssertEqual(dynamic.count, 4)
        XCTAssertTrue(dynamic.allSatisfy { $0 == .cpuAndNeuralEngine })
        let samples = try await publicSamples()
        _ = try await runtime.voiceprint(samples, ordinal: 0, generation: 0, version: 0)
        let camp = await runtime.loadedCAMComputeUnits()
        XCTAssertEqual(camp, .init(preprocessor: .cpuOnly, embedding: .cpuOnly))
        await runtime.close()
        let unloaded = await runtime.loadedCAMComputeUnits()
        XCTAssertNil(unloaded)
        print("LIVE_LOADED_COMPUTE dynamic=\(dynamic.map(\.rawValue)) CAM=\(String(describing: camp)); actual default dynamic CPU/ANE, both CAM models CPU-only.")
    }

    func testCPUOverrideLoadsAllSixActualModelsOnCPU() async throws {
        let directories = try directories()
        let assets = try LiveSpeakerAssets(dynamic: directories.dynamic, camp: directories.camp,
                                          modelIdentifier: SpeakerAnalysisEngine.modelIdentifier(at: directories.camp))
        let runtime = try LiveSpeakerNativeRuntime(assets: assets, meetingID: "CPU-override", cpuOnly: true)
        let dynamic = await runtime.loadedDynamicComputeUnits
        XCTAssertEqual(dynamic, Array(repeating: .cpuOnly, count: 4))
        _ = try await runtime.voiceprint(publicSamples(), ordinal: 0, generation: 0, version: 0)
        let camp = await runtime.loadedCAMComputeUnits()
        XCTAssertEqual(camp, .init(preprocessor: .cpuOnly, embedding: .cpuOnly))
        await runtime.close()
        print("LIVE_LOADED_CPU_OVERRIDE dynamic=\(dynamic.map(\.rawValue)) CAM=\(String(describing: camp))")
    }

    func testOriginalSDKLoaderAndProcessorDefaultsArePreserved() throws {
        let directories = try directories()
        let dynamic = try DynamicSpeakerModelStore.loadVerified(directory: directories.dynamic)
        for model in [dynamic.segmentationModel, dynamic.fbankModel, dynamic.embeddingModel, dynamic.pldaRhoModel] {
            XCTAssertEqual(model.configuration.computeUnits, .all)
        }
        let originalLoader: (URL) throws -> CampPlusModels = CampPlusModels.load(from:)
        let models = try originalLoader(directories.camp)
        XCTAssertEqual(models.preprocessor.configuration.computeUnits, .cpuOnly)
        XCTAssertEqual(models.model.configuration.computeUnits, .cpuAndGPU)
        XCTAssertEqual(VoiceprintProcessor.Configuration().embeddingComputeUnits, .cpuAndGPU)
    }

    func testBothProductionProcessorInitializersThreadExplicitCPUAndPreserveOfflineDefaults() async throws {
        let directories = try directories()
        let database = try AppDatabase.inMemory()
        let matcher = VoiceprintMatcher(speakers: SpeakerRepository(database), modelIdentifier: "configuration-test")
        var configuration = VoiceprintProcessor.Configuration(minimumSampleDuration: 2, idleUnloadDelay: .seconds(10))
        let samples = try await publicSamples()
        for computeUnits in [MLComputeUnits.cpuAndGPU, .cpuOnly] {
            if computeUnits == .cpuOnly { configuration.embeddingComputeUnits = .cpuOnly }
            let processors = [
                VoiceprintProcessor(configuration: configuration, modelDirectory: directories.camp),
                VoiceprintProcessor(configuration: configuration, modelDirectory: directories.camp, matcher: matcher)
            ]
            for processor in processors {
                let handle = try await processor.submit(.init(
                    meetingId: "configuration-test", speakerSlot: 0, generation: 0,
                    audio: samples, sampleRate: 16_000,
                    finalizedSegments: [.init(speakerIndex: 0, startFrame: 0, endFrame: samples.count,
                                              frameDurationSeconds: 1.0 / 16_000)]))
                _ = try await handle.value()
                let loaded = await processor.loadedComputeUnits()
                XCTAssertEqual(loaded, .init(preprocessor: .cpuOnly, embedding: computeUnits))
                await processor.shutdownAndDrain()
            }
        }
    }

    func testBackgroundDuringCAMRetainsPermitUntilPhysicalCompletionAndDefersMoreWork() async throws {
        try await assertCAMDrain(background: true)
    }

    func testStopDuringCAMRetainsPermitUntilPhysicalCompletionAndDefersMoreWork() async throws {
        try await assertCAMDrain(background: false)
    }

    private func assertCAMDrain(background: Bool) async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "CPU cancellation", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        let probe = LiveCAMCPUProbe()
        let runtime = LiveCAMCPUControlledRuntime(probe: probe)
        let slots = LiveTestAdmission()
        let live = LiveDynamicSpeakers(
            database: database, meetingID: meeting.id, deviceID: "test", admission: slots.admission,
            prepareAssets: { .init(dynamic: URL(filePath: "."), camp: URL(filePath: "."), modelIdentifier: "CPU-test") },
            makeRuntime: { _ in runtime })
        await live.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await probe.waitForInference()
        if background { live.setActive(false) } else { live.close() }
        await probe.waitForCancellation()
        XCTAssertNil(live.authorization.generation)
        await live.ingest(.init(index: 1, startFrame: 160_000, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        let held = await slots.count
        let before = await probe.snapshot()
        XCTAssertEqual(held, 1)
        XCTAssertEqual(before.inferences, 1)
        XCTAssertEqual(before.unloads, 0)
        let competingPermit = await slots.acquire()
        XCTAssertNil(competingPermit, "Cancellation cannot admit another physical native job before CAM drain.")
        await probe.completeInference()
        await live.waitForIdle()
        let released = await slots.count
        let after = await probe.snapshot()
        let speakers = try await SpeakerRepository(database).fetchAll()
        XCTAssertEqual(released, 0)
        XCTAssertEqual(after.unloads, 1)
        XCTAssertTrue(speakers.isEmpty)
        live.close()
    }

    private func publicSamples() async throws -> [Float] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = ProcessInfo.processInfo.environment["TRANSCRIPT_LIVE_LATENCY_FIXTURE"].map { URL(filePath: $0) }
            ?? root.appending(path: "Audio/acceptance/librispeech-two-voices-alternating.wav")
        let reader = try RecordedAudioReader(url: fixture)
        var samples: [Float] = []
        while samples.count < 64_000, let chunk = await reader.next() { samples.append(contentsOf: chunk.samples) }
        try await reader.checkFailure()
        return Array(samples.prefix(64_000))
    }
}

private actor LiveCAMCPUProbe {
    private var inferences = 0
    private var unloads = 0
    private var inferenceWaiter: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var physical: CheckedContinuation<Void, Never>?
    private var cancelled = false
    func infer() async -> [Float] {
        inferences += 1
        inferenceWaiter?.resume()
        inferenceWaiter = nil
        await withCheckedContinuation { physical = $0 }
        return [1] + Array(repeating: 0, count: 191)
    }
    func waitForInference() async {
        if inferences == 0 { await withCheckedContinuation { inferenceWaiter = $0 } }
    }
    func cancelledJob() {
        cancelled = true
        cancellationWaiter?.resume()
        cancellationWaiter = nil
    }
    func waitForCancellation() async {
        if !cancelled { await withCheckedContinuation { cancellationWaiter = $0 } }
    }
    func completeInference() { physical?.resume(); physical = nil }
    func unload() { unloads += 1 }
    func snapshot() -> (inferences: Int, unloads: Int) { (inferences, unloads) }
}

private actor LiveCAMCPUControlledRuntime: LiveSpeakerInferring {
    private let probe: LiveCAMCPUProbe
    private let processor: VoiceprintProcessor
    init(probe: LiveCAMCPUProbe) {
        self.probe = probe
        var configuration = VoiceprintProcessor.Configuration(
            maximumOutstandingJobs: 1, maximumOutstandingFrames: 80_000, minimumSampleDuration: 2)
        configuration.embeddingComputeUnits = .cpuOnly
        processor = VoiceprintProcessor(configuration: configuration, inference: .init(
            load: {}, infer: { _ in await probe.infer() }, unload: { await probe.unload() }))
    }
    func extract(_ samples: [Float]) -> CompletedWindowEvidence { LiveSpeakerFixture.window() }
    func cluster(_ rows: [CompletedWindowEvidence.Row]) -> EvidenceCohortResult {
        .init(runID: UUID(), rowIDs: rows.map(\.id), assignments: Array(repeating: 0, count: rows.count))
    }
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) async throws -> [Float]? {
        let handle = try await processor.submit(.init(
            meetingId: "CPU-test", speakerSlot: ordinal, generation: generation, evidenceVersion: version,
            audio: samples, sampleRate: 16_000,
            finalizedSegments: [.init(speakerIndex: ordinal, startFrame: 0, endFrame: samples.count,
                                      frameDurationSeconds: 1.0 / 16_000)]))
        do { return try await handle.value().embedding! }
        catch {
            await probe.cancelledJob()
            await handle.cancelAndWait()
            throw error
        }
    }
    func close() async { await processor.shutdownAndDrain() }
}
