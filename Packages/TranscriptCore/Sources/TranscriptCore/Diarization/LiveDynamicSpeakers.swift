import Foundation
import FluidAudio
import CoreML

public struct LiveSpeakerAdmission: Sendable {
    let acquire: @Sendable () async -> UUID?
    let release: @Sendable (UUID) async -> Void
    public init(acquire: @escaping @Sendable () async -> UUID?, release: @escaping @Sendable (UUID) async -> Void) {
        self.acquire = acquire
        self.release = release
    }
}

public enum LiveSpeakerStatus: Sendable, Equatable {
    case waitingForContext, preparingModels, identifying, published, paused, busy
    case modelsUnavailable, processingFailed, storageFailed, capacityReached
}

struct LiveSpeakerAssets: Sendable {
    let dynamic: URL
    let camp: URL
    let modelIdentifier: String
}

protocol LiveSpeakerInferring: Sendable {
    func extract(_ samples: [Float]) async throws -> CompletedWindowEvidence
    func cluster(_ rows: [CompletedWindowEvidence.Row]) async throws -> EvidenceCohortResult
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) async throws -> [Float]
    func close() async
}

actor LiveSpeakerNativeRuntime: LiveSpeakerInferring {
    private var manager: OfflineDiarizerManager?
    private let processor: VoiceprintProcessor
    private let meetingID: String
    private let assets: LiveSpeakerAssets
    let loadedDynamicComputeUnits: [MLComputeUnits]

    init(assets: LiveSpeakerAssets, meetingID: String, cpuOnly: Bool) throws {
        let manager = OfflineDiarizerManager(config: EvidenceAdapter.configuration())
        let models = try DynamicSpeakerModelStore.loadVerified(
            directory: assets.dynamic, cpuOnly: cpuOnly, computeUnits: LiveDynamicSpeakers.computeUnits)
        loadedDynamicComputeUnits = [
            models.segmentationModel, models.fbankModel, models.embeddingModel, models.pldaRhoModel
        ].map { $0.configuration.computeUnits }
        manager.initialize(models: models)
        self.manager = manager
        self.meetingID = meetingID
        self.assets = assets
        var configuration = VoiceprintProcessor.Configuration(
            maximumOutstandingJobs: 1, maximumOutstandingFrames: 80_000,
            minimumSampleDuration: 2, maximumSampleDuration: 5, idleUnloadDelay: .seconds(1)
        )
        configuration.embeddingComputeUnits = .cpuOnly
        processor = VoiceprintProcessor(configuration: configuration, modelDirectory: assets.camp)
    }

    func loadedCAMComputeUnits() async -> VoiceprintLoadedComputeUnits? {
        await processor.loadedComputeUnits()
    }

    func extract(_ samples: [Float]) async throws -> CompletedWindowEvidence {
        guard let manager else { throw CancellationError() }
        return try await manager.prepareCompletedWindowEvidence(samples: samples)
    }
    func cluster(_ rows: [CompletedWindowEvidence.Row]) throws -> EvidenceCohortResult {
        guard let manager else { throw CancellationError() }
        return try manager.clusterEvidenceRows(rows)
    }
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) async throws -> [Float] {
        guard try SpeakerAnalysisEngine.modelIdentifier(at: assets.camp) == assets.modelIdentifier else {
            throw VoiceprintProcessorError.invalidEmbedding
        }
        // These compacted samples came exclusively from intersection-verified clean
        // source ranges. The selector applies its unchanged physical and 2–5s gates.
        let handle = try await processor.submit(.init(
            meetingId: meetingID, speakerSlot: ordinal, generation: generation, evidenceVersion: version,
            audio: samples, sampleRate: 16_000,
            finalizedSegments: [.init(speakerIndex: ordinal, startFrame: 0, endFrame: samples.count,
                                      frameDurationSeconds: 1.0 / 16_000)]
        ))
        do {
            let result = try await handle.value()
            guard result.evidence.cleanFrameCount >= 32_000, let vector = result.embedding, vector.count == 192 else {
                throw VoiceprintProcessorError.invalidEmbedding
            }
            guard try SpeakerAnalysisEngine.modelIdentifier(at: assets.camp) == assets.modelIdentifier else {
                throw VoiceprintProcessorError.invalidEmbedding
            }
            return vector
        } catch {
            await handle.cancelAndWait()
            throw error
        }
    }
    func close() async {
        await processor.shutdownAndDrain()
        manager = nil
    }
}

/// Optional, loss-aware speaker inference. Ingestion copies into a fixed ring and
/// never awaits models or a native permit; archive/ASR have independent streams.
public actor LiveDynamicSpeakers {
    private struct StorageFailure: Error {}
    public static let computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    public nonisolated let authorization: LiveSpeakerAuthorization
    public nonisolated let events: AsyncStream<LiveSpeakerStatus>
    private let continuation: AsyncStream<LiveSpeakerStatus>.Continuation
    private let repository: LiveSpeakerRepository
    private let admission: LiveSpeakerAdmission
    private let prepareAssets: @Sendable () async throws -> LiveSpeakerAssets
    private let makeRuntime: @Sendable (LiveSpeakerAssets) async throws -> any LiveSpeakerInferring
    private var assets: LiveSpeakerAssets?
    private var pcm = LiveSpeakerPCM()
    private var registry = LiveIdentityRegistry()
    private var assembler = LiveSpeakerAssembler()
    private var pendingCAM: [String: [Float]] = [:]
    private var bound: Set<String> = []
    private var bindingCapacityLimited = false
    private var worker: Task<Void, Never>?
    private var lastAttempted: Int64 = -1
    private var inputGeneration = 0
    private var inputRevision = 0
    private var blockedGeneration: Int?
    private var began = false
    private var processedWindows = 0

    public init(database: AppDatabase, meetingID: String, deviceID: String,
                downloader: ASRModelDownloader, admission: LiveSpeakerAdmission, cpuOnly: Bool = false) {
        let authorization = LiveSpeakerAuthorization()
        self.authorization = authorization
        repository = LiveSpeakerRepository(database: database, meetingID: meetingID, epoch: UUID().uuidString,
                                           deviceID: deviceID, authorization: authorization)
        self.admission = admission
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        prepareAssets = {
            let dynamic = try await downloader.ensureDynamicSpeakersInstalled()
            let camp = try await downloader.ensureCampPlusInstalled()
            return try LiveSpeakerAssets(dynamic: dynamic, camp: camp, modelIdentifier: SpeakerAnalysisEngine.modelIdentifier(at: camp))
        }
        makeRuntime = { try LiveSpeakerNativeRuntime(assets: $0, meetingID: meetingID, cpuOnly: cpuOnly) }
        continuation.yield(.waitingForContext)
    }

    init(database: AppDatabase, meetingID: String, deviceID: String, authorization: LiveSpeakerAuthorization = .init(),
         admission: LiveSpeakerAdmission,
         prepareAssets: @escaping @Sendable () async throws -> LiveSpeakerAssets,
         makeRuntime: @escaping @Sendable (LiveSpeakerAssets) async throws -> any LiveSpeakerInferring) {
        self.authorization = authorization
        repository = LiveSpeakerRepository(database: database, meetingID: meetingID, epoch: UUID().uuidString,
                                           deviceID: deviceID, authorization: authorization)
        self.admission = admission
        self.prepareAssets = prepareAssets
        self.makeRuntime = makeRuntime
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    public nonisolated func setActive(_ active: Bool) {
        authorization.setActive(active)
        if !active { Task { await cancelOptionalWork() } }
    }

    /// Does not wait for native work. Its permit remains held until physical drain.
    public nonisolated func close() {
        authorization.close()
        Task { await cancelOptionalWork(); await finishEvents() }
    }

    public func ingest(_ chunk: AudioChunk) {
        guard let generation = authorization.generation, blockedGeneration != generation else {
            pcm.reset(at: Int64(max(0, chunk.startFrame)))
            return
        }
        if inputGeneration != generation {
            inputGeneration = generation
            inputRevision += 1
            pcm.reset(at: Int64(chunk.startFrame))
            assembler.invalidateCoverage()
            pendingCAM.removeAll()
            bindingCapacityLimited = false
            continuation.yield(.waitingForContext)
        }
        do {
            if try pcm.append(chunk) {
                inputRevision += 1
                assembler.invalidateCoverage()
                pendingCAM.removeAll()
                continuation.yield(.waitingForContext)
            }
            schedule()
        } catch {
            inputRevision += 1
            pcm.reset(at: Int64(max(0, chunk.startFrame)))
            assembler.invalidateCoverage()
            pendingCAM.removeAll()
            continuation.yield(.processingFailed)
        }
    }

    public func reconcile() async {
        guard began, let generation = authorization.generation else { return }
        do { try await repository.reconcile(generation: generation) }
        catch is CancellationError {}
        catch { continuation.yield(.storageFailed) }
    }

    /// Late final ASR may consume already committed evidence after native revocation.
    /// This cannot create identities/templates, replace user edits, or beat offline ownership.
    public func reconcileAcceptedEvidence() async {
        guard began else { return }
        do { try await repository.reconcile(generation: nil) }
        catch VoiceprintBindingError.staleExpectation {}
        catch { continuation.yield(.storageFailed) }
    }

    public func waitForIdle() async { await worker?.value }

    struct Metrics: Sendable {
        let pcmFrames: Int
        let camFrames: Int
        let identities: Int
        let windows: Int
        let activeWorkers: Int
        let processed: Int
    }
    func metrics() -> Metrics {
        .init(pcmFrames: pcm.count, camFrames: pendingCAM.values.reduce(0) { $0 + $1.count },
              identities: registry.identities.count, windows: assembler.retainedWindowCount,
              activeWorkers: worker == nil ? 0 : 1, processed: processedWindows)
    }

    private func cancelOptionalWork() {
        guard authorization.generation == nil else { return }
        inputRevision += 1
        worker?.cancel()
        pcm.reset(at: pcm.upper)
        assembler.invalidateCoverage()
        pendingCAM.removeAll()
        continuation.yield(.paused)
    }
    private func finishEvents() { continuation.finish() }

    private func schedule() {
        guard worker == nil, let generation = authorization.generation,
              blockedGeneration != generation, pcm.latestWindowStart(after: lastAttempted) != nil else { return }
        worker = Task {
            await runLatest(generation: generation)
            worker = nil
            schedule()
        }
    }

    private func runLatest(generation: Int) async {
        if assets == nil {
            continuation.yield(.preparingModels)
            do { assets = try await prepareAssets() }
            catch {
                if authorization.generation == generation {
                    blockedGeneration = generation
                    continuation.yield(.modelsUnavailable)
                }
                return
            }
        }
        guard authorization.generation == generation, !Task.isCancelled, let assets,
              let start = pcm.latestWindowStart(after: lastAttempted) else { return }
        lastAttempted = start
        guard let permit = await admission.acquire() else { continuation.yield(.busy); return }
        do {
            try Task.checkCancellation()
            guard authorization.generation == generation else { throw CancellationError() }
            if !began {
                do { try await repository.begin(generation: generation) }
                catch is CancellationError { throw CancellationError() }
                catch { throw StorageFailure() }
                began = true
            }
            guard let window = pcm.latestWindow(after: start - 1), window.start == start else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard authorization.generation == generation else { throw CancellationError() }
            let sourceRevision = inputRevision
            continuation.yield(.identifying)
            let runtime = try await makeRuntime(assets)
            do {
                try await analyze(window, runtime: runtime, assets: assets, generation: generation, sourceRevision: sourceRevision)
                await runtime.close()
            } catch {
                await runtime.close()
                throw error
            }
        } catch is CancellationError {
            // Optional results are revoked; archive and the next capture never wait.
        } catch is StorageFailure {
            if authorization.generation == generation {
                blockedGeneration = generation
                continuation.yield(.storageFailed)
            }
        } catch {
            if authorization.generation == generation {
                blockedGeneration = generation
                continuation.yield(.processingFailed)
            }
        }
        await admission.release(permit)
    }

    private func analyze(
        _ window: (start: Int64, samples: [Float]), runtime: any LiveSpeakerInferring,
        assets: LiveSpeakerAssets, generation: Int, sourceRevision: Int
    ) async throws {
        guard authorization.generation == generation, inputRevision == sourceRevision else { throw CancellationError() }
        let evidence = try await runtime.extract(window.samples)
        let validated = try LiveWindowEvidence(start: window.start, evidence: evidence)
        let clustered = try await runtime.cluster(registry.cohort(adding: validated.rows))
        try Task.checkCancellation()
        guard authorization.generation == generation, inputRevision == sourceRevision else { throw CancellationError() }
        var nextRegistry = registry
        var nextAssembler = assembler
        let identities = try nextRegistry.resolve(rows: validated.rows, result: clustered)
        let spans = try nextAssembler.append(start: window.start, mask: validated.mask, identities: identities)
        var samplesByIdentity = pendingCAM
        pendingCAM.removeAll()
        collectCAM(spans: spans, window: window, pending: &samplesByIdentity)
        var voices: [LiveSpeakerVoice] = []
        for identity in nextRegistry.identities where (samplesByIdentity[identity.id]?.count ?? 0) >= 32_000 {
            let samples = samplesByIdentity.removeValue(forKey: identity.id)!
            let vector = try await runtime.voiceprint(
                samples, ordinal: identity.ordinal, generation: generation, version: Int(window.start / 32_000))
            voices.append(.init(identityID: identity.id, embedding: vector, cleanFrameCount: samples.count))
        }
        try Task.checkCancellation()
        guard inputRevision == sourceRevision else { throw CancellationError() }
        do {
            let published = try await repository.publish(
                generation: generation, identities: nextRegistry.identities.map { .init(id: $0.id, ordinal: $0.ordinal) },
                spans: spans, voices: voices, modelIdentifier: assets.modelIdentifier)
            registry = nextRegistry
            assembler = nextAssembler
            // User-deleted bindings must not be automatically resurrected.
            bound.formUnion(published.bound)
            bindingCapacityLimited = bindingCapacityLimited || published.capacityLimited
            if authorization.generation == generation, inputRevision == sourceRevision {
                pendingCAM = samplesByIdentity
            } else {
                assembler.invalidateCoverage()
            }
            try await repository.reconcile(generation: generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StorageFailure()
        }
        processedWindows += 1
        continuation.yield(bindingCapacityLimited || registry.identities.count == LiveSpeakerLimits.identities
                           ? .capacityReached : bound.isEmpty ? .waitingForContext : .published)
    }

    private func collectCAM(spans: [LiveSpeakerSpan], window: (start: Int64, samples: [Float]), pending: inout [String: [Float]]) {
        let scale = LiveSpeakerLimits.ticksPerSample
        guard !bindingCapacityLimited else { pending.removeAll(); return }
        let observed = Set(spans.filter { !$0.unknown }.compactMap(\.identityID))
        pending = pending.filter { observed.contains($0.key) }
        for span in spans {
            guard !span.unknown, let id = span.identityID, !bound.contains(id),
                  span.startTick >= window.start * scale else { continue }
            if pending[id] == nil {
                guard pending.count < 2 else { continue }
                pending[id] = []
            }
            let lower = Int((span.startTick + scale - 1) / scale - window.start)
            let upper = Int(span.endTick / scale - window.start)
            guard lower >= 0, upper <= window.samples.count, upper > lower else { continue }
            let available = 80_000 - (pending[id]?.count ?? 0)
            if available > 0 { pending[id]?.append(contentsOf: window.samples[lower..<min(upper, lower + available)]) }
        }
    }
}
