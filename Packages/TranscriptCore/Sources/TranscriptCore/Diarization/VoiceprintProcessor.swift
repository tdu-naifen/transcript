import FluidAudio
import Foundation

public struct VoiceprintRequest: Sendable {
  public let meetingId: String
  public let speakerSlot: Int
  public let generation: Int
  /// Monotonic token for the finalized audio evidence available to this slot.
  public let evidenceVersion: Int
  public let audio: [Float]
  public let sampleRate: Int
  public let finalizedSegments: [DiarizerSegment]

  public init(
    meetingId: String,
    speakerSlot: Int,
    generation: Int,
    evidenceVersion: Int? = nil,
    audio: [Float],
    sampleRate: Int,
    finalizedSegments: [DiarizerSegment]
  ) {
    self.meetingId = meetingId
    self.speakerSlot = speakerSlot
    self.generation = generation
    self.evidenceVersion = evidenceVersion ?? generation
    self.audio = audio
    self.sampleRate = sampleRate
    self.finalizedSegments = finalizedSegments
  }
}

public enum VoiceprintProcessingOutcome: Sendable, Equatable {
  case embedded([Float])
  case needsMoreAudio
}

public struct VoiceprintProcessingResult: Sendable, Equatable {
  public let meetingId: String
  public let speakerSlot: Int
  public let generation: Int
  public let outcome: VoiceprintProcessingOutcome
  public let match: VoiceprintMatchResult?
  public let evidence: VoiceprintSampleEvidence

  public var embedding: [Float]? {
    guard case .embedded(let value) = outcome else { return nil }
    return value
  }
}

public enum VoiceprintProcessorError: Error, Equatable, Sendable {
  case busy
  case duplicateEvidence
  case invalidEmbedding
  case shutDown
}

public struct VoiceprintJobHandle: Sendable {
  public let id: UUID
  private let result: VoiceprintJobResult
  private let cancelJob: @Sendable (UUID) async -> Void
  private let cancelAndWaitJob: @Sendable (UUID) async -> Void

  fileprivate init(
    id: UUID,
    result: VoiceprintJobResult,
    cancelJob: @escaping @Sendable (UUID) async -> Void,
    cancelAndWaitJob: @escaping @Sendable (UUID) async -> Void
  ) {
    self.id = id
    self.result = result
    self.cancelJob = cancelJob
    self.cancelAndWaitJob = cancelAndWaitJob
  }

  public func value() async throws -> VoiceprintProcessingResult {
    try await withTaskCancellationHandler {
      try await result.value()
    } onCancel: {
      Task { await cancelJob(id) }
    }
  }

  public func cancel() async {
    await cancelJob(id)
  }

  /// Cancels this job and waits until its physical inference has stopped.
  ///
  /// Queued work completes this wait immediately. For active Core ML work, the
  /// wait ends only after the worker has observed the inference completion and
  /// released the job's resources.
  public func cancelAndWait() async {
    await cancelAndWaitJob(id)
  }
}

/// Internal deterministic inference seam. Product callers use ``VoiceprintProcessor/init(configuration:modelDirectory:)``.
struct VoiceprintInference: Sendable {
  let load: @Sendable () async throws -> Void
  let infer: @Sendable ([Float]) async throws -> [Float]
  let unload: @Sendable () async -> Void
}

fileprivate actor VoiceprintJobResult {
  private var completion: Result<VoiceprintProcessingResult, any Error>?
  private var waiters: [CheckedContinuation<VoiceprintProcessingResult, any Error>] = []
  private var physicalComplete = false
  private var physicalWaiters: [CheckedContinuation<Void, Never>] = []

  func value() async throws -> VoiceprintProcessingResult {
    if let completion { return try completion.get() }
    return try await withCheckedThrowingContinuation { waiters.append($0) }
  }

  func finish(_ completion: Result<VoiceprintProcessingResult, any Error>) {
    guard self.completion == nil else { return }
    self.completion = completion
    let waiters = self.waiters
    self.waiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume(with: completion) }
  }

  func finishPhysical() {
    guard !physicalComplete else { return }
    physicalComplete = true
    let waiters = physicalWaiters
    physicalWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  func waitForPhysicalCompletion() async {
    guard !physicalComplete else { return }
    await withCheckedContinuation { physicalWaiters.append($0) }
  }
}

private actor CampPlusRuntime {
  private let directory: URL
  private var embedder: CampPlusEmbedder?

  init(directory: URL) {
    self.directory = directory
  }

  func load() async throws {
    if embedder == nil {
      embedder = CampPlusEmbedder(models: try CampPlusModels.load(from: directory))
    }
  }

  func infer(_ samples: [Float]) async throws -> [Float] {
    guard let embedder else { throw VoiceprintProcessorError.shutDown }
    return try await embedder.embed(audio: samples)
  }

  func unload() {
    embedder = nil
  }
}

private actor VoiceprintInferenceWorker {
  private let inference: VoiceprintInference
  private let match: @Sendable ([Float], TimeInterval) async throws -> VoiceprintMatchResult?
  private let selector: VoiceprintSampleSelector
  private let idleUnloadDelay: Duration
  private var loaded = false
  private var idleUnloadTask: Task<Void, Never>?
  private var activityGeneration = 0

  init(
    inference: VoiceprintInference,
    match: @escaping @Sendable ([Float], TimeInterval) async throws -> VoiceprintMatchResult?,
    selector: VoiceprintSampleSelector,
    idleUnloadDelay: Duration
  ) {
    self.inference = inference
    self.match = match
    self.selector = selector
    self.idleUnloadDelay = idleUnloadDelay
  }

  func process(_ request: VoiceprintRequest) async throws -> VoiceprintProcessingResult {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
    activityGeneration += 1
    let generation = activityGeneration
    let selection: VoiceprintSelectedSample
    do {
      selection = try selector.select(
        speakerIndex: request.speakerSlot,
        audio: request.audio,
        sampleRate: request.sampleRate,
        finalizedSegments: request.finalizedSegments
      )
    } catch let error as VoiceprintSampleSelectionError {
      if case .insufficientCleanAudio(_, let availableFrames) = error {
        scheduleIdleUnload(after: generation)
        return VoiceprintProcessingResult(
          meetingId: request.meetingId,
          speakerSlot: request.speakerSlot,
          generation: request.generation,
          outcome: .needsMoreAudio,
          match: nil,
          evidence: VoiceprintSampleEvidence(
            ranges: [], cleanFrameCount: availableFrames, sampleRate: request.sampleRate
          )
        )
      }
      scheduleIdleUnload(after: generation)
      throw error
    }

    if !loaded {
      do {
        try await inference.load()
        loaded = true
      } catch {
        loaded = false
        throw error
      }
    }
    let embedding: [Float]
    do {
      guard let normalized = FloatVector.normalized(try await inference.infer(selection.samples))
      else {
        throw VoiceprintProcessorError.invalidEmbedding
      }
      embedding = normalized
    } catch {
      scheduleIdleUnload(after: generation)
      throw error
    }
    scheduleIdleUnload(after: generation)
    return VoiceprintProcessingResult(
      meetingId: request.meetingId,
      speakerSlot: request.speakerSlot,
      generation: request.generation,
      outcome: .embedded(embedding),
      match: try await match(embedding, selection.evidence.cleanDuration),
      evidence: selection.evidence
    )
  }

  func unload() async {
    activityGeneration += 1
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
    guard loaded else { return }
    await inference.unload()
    loaded = false
  }

  private func scheduleIdleUnload(after generation: Int) {
    let delay = idleUnloadDelay
    idleUnloadTask?.cancel()
    idleUnloadTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.unloadIfIdle(generation: generation)
    }
  }

  private func unloadIfIdle(generation: Int) async {
    guard generation == activityGeneration, loaded else { return }
    await inference.unload()
    loaded = false
    idleUnloadTask = nil
  }
}

/// Bounded admission actor for serial CAM++ inference. `submit` only admits work; callers
/// await each handle independently. Cancellation removes queued jobs immediately and
/// suppresses results from an already-running Core ML prediction.
public actor VoiceprintProcessor {
  public struct Configuration: Sendable, Equatable {
    public var maximumOutstandingJobs: Int
    public var maximumOutstandingFrames: Int
    public var minimumSampleDuration: TimeInterval
    public var maximumSampleDuration: TimeInterval
    public var idleUnloadDelay: Duration

    public init(
      maximumOutstandingJobs: Int = 4,
      maximumOutstandingFrames: Int = 320_000,
      minimumSampleDuration: TimeInterval = 1,
      maximumSampleDuration: TimeInterval = 5,
      idleUnloadDelay: Duration = .seconds(30)
    ) {
      self.maximumOutstandingJobs = maximumOutstandingJobs
      self.maximumOutstandingFrames = maximumOutstandingFrames
      self.minimumSampleDuration = minimumSampleDuration
      self.maximumSampleDuration = maximumSampleDuration
      self.idleUnloadDelay = idleUnloadDelay
    }
  }

  private struct EvidenceKey: Hashable {
    let meetingId: String
    let speakerSlot: Int
    let evidenceVersion: Int
  }

  private struct Job: Sendable {
    let id: UUID
    let request: VoiceprintRequest
    let result: VoiceprintJobResult
  }

  private let configuration: Configuration
  private let worker: VoiceprintInferenceWorker
  private let admissionGate: (@Sendable () async -> Void)?
  private var queued: [Job] = []
  private var active: Job?
  private var cancelled: Set<UUID> = []
  private var activeEvidence: Set<EvidenceKey> = []
  private var completedEvidence: Set<EvidenceKey> = []
  private var completedEvidenceOrder: [EvidenceKey] = []
  private var outstandingFrames = 0
  private var draining: [CheckedContinuation<Void, Never>] = []
  private var isShutDown = false

  public init(
    configuration: Configuration = .init(),
    modelDirectory: URL = DiarizationModelStore.campPlusDirectory()
  ) {
    let runtime = CampPlusRuntime(directory: modelDirectory)
    self.configuration = configuration
    self.admissionGate = nil
    self.worker = Self.makeWorker(
      configuration: configuration,
      inference: VoiceprintInference(
        load: { try await runtime.load() },
        infer: { try await runtime.infer($0) },
        unload: { await runtime.unload() }
      ),
      matcher: nil
    )
  }

  public init(
    configuration: Configuration = .init(),
    modelDirectory: URL = DiarizationModelStore.campPlusDirectory(),
    matcher: VoiceprintMatcher
  ) {
    let runtime = CampPlusRuntime(directory: modelDirectory)
    self.configuration = configuration
    self.admissionGate = nil
    self.worker = Self.makeWorker(
      configuration: configuration,
      inference: VoiceprintInference(
        load: { try await runtime.load() },
        infer: { try await runtime.infer($0) },
        unload: { await runtime.unload() }
      ),
      matcher: matcher
    )
  }

  init(
    configuration: Configuration = .init(),
    matcher: VoiceprintMatcher? = nil,
    inference: VoiceprintInference,
    admissionGate: (@Sendable () async -> Void)? = nil
  ) {
    self.configuration = configuration
    self.admissionGate = admissionGate
    self.worker = Self.makeWorker(
      configuration: configuration, inference: inference, matcher: matcher
    )
  }

  private static func makeWorker(
    configuration: Configuration,
    inference: VoiceprintInference,
    matcher: VoiceprintMatcher?
  ) -> VoiceprintInferenceWorker {
    VoiceprintInferenceWorker(
      inference: inference,
      match: { embedding, duration in
        try await matcher?.match(embedding: embedding, cleanDuration: duration)
      },
      selector: VoiceprintSampleSelector(
        configuration: .init(
          minimumDuration: configuration.minimumSampleDuration,
          maximumDuration: configuration.maximumSampleDuration
        )),
      idleUnloadDelay: configuration.idleUnloadDelay
    )
  }

  public func submit(_ request: VoiceprintRequest) async throws -> VoiceprintJobHandle {
    if let admissionGate {
      await admissionGate()
    }
    guard !isShutDown else { throw VoiceprintProcessorError.shutDown }
    let evidenceKey = EvidenceKey(
      meetingId: request.meetingId,
      speakerSlot: request.speakerSlot,
      evidenceVersion: request.evidenceVersion
    )
    guard !activeEvidence.contains(evidenceKey), !completedEvidence.contains(evidenceKey) else {
      throw VoiceprintProcessorError.duplicateEvidence
    }
    let outstandingJobs = queued.count + (active == nil ? 0 : 1)
    guard configuration.maximumOutstandingJobs > 0,
      outstandingJobs < configuration.maximumOutstandingJobs,
      configuration.maximumOutstandingFrames > 0,
      request.audio.count <= configuration.maximumOutstandingFrames,
      outstandingFrames <= configuration.maximumOutstandingFrames - request.audio.count
    else {
      throw VoiceprintProcessorError.busy
    }
    activeEvidence.insert(evidenceKey)

    let id = UUID()
    let result = VoiceprintJobResult()
    queued.append(Job(id: id, request: request, result: result))
    outstandingFrames += request.audio.count
    startNextIfNeeded()
    return VoiceprintJobHandle(
      id: id,
      result: result,
      cancelJob: { [weak self] id in await self?.cancel(id: id) },
      cancelAndWaitJob: { [weak self] id in await self?.cancelAndWait(id: id) }
    )
  }

  public func drain() async {
    guard active != nil || !queued.isEmpty else { return }
    await withCheckedContinuation { draining.append($0) }
  }

  public func shutdownAndDrain() async {
    isShutDown = true
    let queued = self.queued
    self.queued.removeAll(keepingCapacity: false)
    for job in queued {
      outstandingFrames -= job.request.audio.count
      activeEvidence.remove(evidenceKey(for: job.request))
      await job.result.finish(.failure(CancellationError()))
      await job.result.finishPhysical()
    }
    if let active {
      cancelled.insert(active.id)
      await active.result.finish(.failure(CancellationError()))
    }
    await drain()
    await worker.unload()
  }

  private func cancel(id: UUID) async {
    if let index = queued.firstIndex(where: { $0.id == id }) {
      let job = queued.remove(at: index)
      outstandingFrames -= job.request.audio.count
      activeEvidence.remove(evidenceKey(for: job.request))
      await job.result.finish(.failure(CancellationError()))
      finishDrainIfNeeded()
      return
    }

    guard let active, active.id == id else { return }
    cancelled.insert(id)
    await active.result.finish(.failure(CancellationError()))
  }

  private func cancelAndWait(id: UUID) async {
    if let index = queued.firstIndex(where: { $0.id == id }) {
      let job = queued.remove(at: index)
      outstandingFrames -= job.request.audio.count
      activeEvidence.remove(evidenceKey(for: job.request))
      await job.result.finish(.failure(CancellationError()))
      await job.result.finishPhysical()
      finishDrainIfNeeded()
      return
    }
    guard let active, active.id == id else { return }
    cancelled.insert(id)
    await active.result.finish(.failure(CancellationError()))
    await active.result.waitForPhysicalCompletion()
  }

  private func startNextIfNeeded() {
    guard active == nil, !queued.isEmpty else { return }
    let job = queued.removeFirst()
    active = job
    Task {
      let result: Result<VoiceprintProcessingResult, any Error>
      do {
        result = .success(try await worker.process(job.request))
      } catch {
        result = .failure(error)
      }
      await completed(job: job, result: result)
    }
  }

  private func completed(
    job: Job,
    result: Result<VoiceprintProcessingResult, any Error>
  ) async {
    guard active?.id == job.id else { return }
    outstandingFrames -= job.request.audio.count
    let key = evidenceKey(for: job.request)
    activeEvidence.remove(key)
    if cancelled.remove(job.id) == nil {
      if case .success = result { rememberCompleted(key) }
      await job.result.finish(result)
    }
    await job.result.finishPhysical()
    active = nil
    startNextIfNeeded()
    finishDrainIfNeeded()
  }

  private func evidenceKey(for request: VoiceprintRequest) -> EvidenceKey {
    EvidenceKey(
      meetingId: request.meetingId,
      speakerSlot: request.speakerSlot,
      evidenceVersion: request.evidenceVersion
    )
  }

  private func rememberCompleted(_ key: EvidenceKey) {
    completedEvidence.insert(key)
    completedEvidenceOrder.append(key)
    let limit = max(configuration.maximumOutstandingJobs * 4, 16)
    if completedEvidenceOrder.count > limit {
      completedEvidence.remove(completedEvidenceOrder.removeFirst())
    }
  }

  private func finishDrainIfNeeded() {
    guard active == nil, queued.isEmpty else { return }
    let draining = self.draining
    self.draining.removeAll(keepingCapacity: false)
    for continuation in draining { continuation.resume() }
  }
}
