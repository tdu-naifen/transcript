import CoreML
import FluidAudio
import Foundation

extension SortformerConfig {
    /// The only Sortformer configuration this app may use: `fastV2_1` forced to the
    /// palettized (6-bit) head. Never the fp16 high-context head — it needs ~2.4GB RAM
    /// and can hang ANE compilation on <8GB devices (FluidAudio issue #726). Palettized
    /// is ~330MB for +0.9pp DER, the right trade on iPhone.
    public static let transcriptDefault: SortformerConfig = {
        var config = SortformerConfig.fastV2_1
        config.precision = .palettized
        return config
    }()
}

/// Drives Sortformer diarization from the same 16 kHz mono chunk stream ``LiveTranscriber``
/// consumes for ASR, so the app layer treats both engines the same way.
///
/// `SortformerDiarizer` is a plain class guarded by an internal `NSLock`, not an actor —
/// wrapping it here confines every call to this actor's single execution context instead
/// of relying on that lock.
public actor SpeakerDiarizer {
    public struct Configuration: Sendable {
        /// Path to the compiled (`.mlmodelc`) Sortformer variant directory, e.g. what
        /// ``DiarizationModelStore/sortformerMainModelPath(variant:precision:searchRoots:)``
        /// resolves to. FluidAudio's HuggingFace bundles ship pre-compiled, so this loads
        /// via `MLModel(contentsOf:)` rather than `SortformerDiarizer.initialize(mainModelPath:)`
        /// (which recompiles and expects an uncompiled `.mlpackage`).
        public var mainModelPath: URL
        public var config: SortformerConfig
        public var timelineConfig: DiarizerTimelineConfig
        public var computeUnits: MLComputeUnits?

        public init(
            mainModelPath: URL,
            config: SortformerConfig = .transcriptDefault,
            timelineConfig: DiarizerTimelineConfig = .sortformerDefault,
            computeUnits: MLComputeUnits? = nil
        ) {
            self.mainModelPath = mainModelPath
            self.config = config
            self.timelineConfig = timelineConfig
            self.computeUnits = computeUnits
        }
    }

    public enum Event: Sendable {
        case ready
        /// `finalized` segments the timeline will never revise; `tentative` ones are
        /// still open and the UI should show them as provisional.
        case update(finalized: [DiarizerSegment], tentative: [DiarizerSegment])
        case failed(String)
        case finished
    }

    // `SortformerDiarizer` is a plain (non-Sendable) class; every call to it happens
    // from this actor's single executor, so `nonisolated(unsafe)` here just tells the
    // compiler what the internal `NSLock` already guarantees — it does not widen who
    // can touch it, since the property is never exposed outside this actor.
    private nonisolated(unsafe) let diarizer: SortformerDiarizer
    private let configuration: Configuration
    private var continuation: AsyncStream<Event>.Continuation?
    private var task: Task<Void, Never>?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.diarizer = SortformerDiarizer(
            config: configuration.config,
            timelineConfig: configuration.timelineConfig
        )
    }

    /// Live updates. Call before ``run(chunks:)``.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.continuation?.finish()
        self.continuation = continuation
        return stream
    }

    /// Consumes the chunk stream to completion. A second call while one is running is
    /// ignored, so the model can never be loaded twice by a double tap.
    public func run(chunks: AsyncStream<AudioChunk>) {
        guard task == nil else { return }
        task = Task { await self.consume(chunks) }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// Resets streaming state for a new recording while keeping the model loaded.
    public func reset() {
        diarizer.reset()
    }

    /// Frees the loaded model.
    public func cleanup() {
        diarizer.cleanup()
    }

    private func consume(_ chunks: AsyncStream<AudioChunk>) async {
        do {
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = configuration.computeUnits
                ?? SortformerModels.recommendedComputeUnits(for: configuration.config)
            let mainModel = try MLModel(contentsOf: configuration.mainModelPath, configuration: mlConfig)
            let models = try SortformerModels(config: configuration.config, main: mainModel)
            diarizer.initialize(models: models)
        } catch {
            emit(.failed(String(describing: error)))
            emit(.finished)
            return
        }
        emit(.ready)

        for await chunk in chunks {
            if Task.isCancelled { break }
            do {
                try diarizer.addAudio(chunk.samples, sourceSampleRate: chunk.sampleRate)
                if let update = try diarizer.process() { emit(update) }
            } catch {
                emit(.failed(String(describing: error)))
                break
            }
            if chunk.isFinal { break }
        }

        if !Task.isCancelled {
            do {
                if let update = try diarizer.finalizeSession() { emit(update) }
            } catch {
                emit(.failed(String(describing: error)))
            }
        }

        emit(.finished)
        task = nil
    }

    private func emit(_ update: DiarizerTimelineUpdate) {
        emit(.update(finalized: update.finalizedSegments, tentative: update.tentativeSegments))
    }

    private func emit(_ event: Event) {
        continuation?.yield(event)
        if case .finished = event { continuation?.finish() }
    }
}
