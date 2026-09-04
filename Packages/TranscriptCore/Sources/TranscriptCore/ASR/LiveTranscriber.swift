import FluidAudio
import Foundation

/// Drives the ASR engine from a recording's chunk stream and persists what it finalises.
///
/// The plug-in point PLAN §3.3 left open: `RecordingSession.chunks()` gives an
/// independent broadcast copy, so transcription never competes with the file writer.
/// Everything here is actor-isolated, so the UI can observe ``events()`` without any
/// inference running on the main actor.
public actor LiveTranscriber {
    public struct Configuration: Sendable {
        public var meetingId: String
        public var deviceId: String
        /// Nil in the benchmark harness, where nothing should be written to the database.
        public var utterances: UtteranceRepository?
        public var maxSegmentMs: Int
        /// Directory FluidAudio's `loadModels(from:)` reads — the on-disk bundle
        /// containing `encoder.mlmodelc`, `decoder.mlmodelc`, `joint.mlmodelc`,
        /// `decoder_joint.mlmodelc`, `metadata.json` and `tokenizer.json`.
        public var modelDirectory: URL
        public var language: ASRLanguage

        public init(
            meetingId: String,
            deviceId: String,
            utterances: UtteranceRepository?,
            maxSegmentMs: Int = 30_000,
            modelDirectory: URL = ASRModelStore.bundle().directory,
            language: ASRLanguage = .auto
        ) {
            self.meetingId = meetingId
            self.deviceId = deviceId
            self.utterances = utterances
            self.maxSegmentMs = maxSegmentMs
            self.modelDirectory = modelDirectory
            self.language = language
        }
    }

    private let engine: StreamingNemotronMultilingualAsrManager
    private let configuration: Configuration
    private var continuation: AsyncStream<ASRTranscriptEvent>.Continuation?
    private var task: Task<Void, Never>?

    public init(engine: StreamingNemotronMultilingualAsrManager, configuration: Configuration) {
        self.engine = engine
        self.configuration = configuration
    }

    /// Live partials and finalised lines. Call before ``run(chunks:)``.
    public func events() -> AsyncStream<ASRTranscriptEvent> {
        let (stream, continuation) = AsyncStream<ASRTranscriptEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation?.finish()
        self.continuation = continuation
        return stream
    }

    /// Consumes the chunk stream to completion. A second call while one is running is
    /// ignored, so the ~600 MB model can never be loaded twice by a double tap.
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

    /// Number of chunks processed, for tests and the debug panel.
    public private(set) var processedChunks = 0

    private func consume(_ chunks: AsyncStream<AudioChunk>) async {
        let loadStarted = ContinuousClock.now
        do {
            try await engine.loadModels(from: configuration.modelDirectory)
        } catch {
            emit(.failed(String(describing: error)))
            emit(.finished)
            return
        }
        let loadSeconds = Self.secondsSince(loadStarted)

        await engine.reset()
        await engine.setLanguage(configuration.language.fixedLocaleIdentifier)
        emit(.ready(ASREngineInfo(language: configuration.language, loadSeconds: loadSeconds)))

        var segmenter = TranscriptSegmenter(
            defaultLocale: configuration.language.fixedLocaleIdentifier,
            maxSegmentMs: configuration.maxSegmentMs
        )
        var deliveredTimingCount = 0
        var encounteredError = false

        for await chunk in chunks {
            if Task.isCancelled { break }
            do {
                _ = try await engine.process(samples: chunk.samples)
                processedChunks += 1
                if configuration.language == .auto, let detected = await engine.detectedLanguage() {
                    segmenter.updateDefaultLocale(detected)
                }
                let timings = await engine.getTokenTimings()
                let newTimings = Array(timings.dropFirst(deliveredTimingCount))
                deliveredTimingCount = timings.count
                let output = segmenter.consume(newTimings)
                await deliver(output.finalized)
                if let partial = output.partial { emit(.segment(partial)) }
            } catch {
                emit(.failed(String(describing: error)))
                encounteredError = true
                break
            }
            if chunk.isFinal { break }
        }

        if !Task.isCancelled, !encounteredError {
            do {
                let (_, timings) = try await engine.finishWithTokenTimings()
                let newTimings = Array(timings.dropFirst(deliveredTimingCount))
                await deliver(segmenter.consume(newTimings).finalized)
            } catch {
                emit(.failed(String(describing: error)))
            }
        }

        if let trailing = segmenter.flush() { await deliver([trailing]) }
        emit(.finished)
        task = nil
    }

    private func deliver(_ segments: [ASRSegment]) async {
        guard !segments.isEmpty else { return }
        for segment in segments { emit(.segment(segment)) }
        guard let repository = configuration.utterances else { return }
        let rows = segments
            .filter { !$0.text.isEmpty }
            .map { segment in
                Utterance(
                    meetingId: configuration.meetingId,
                    startMs: segment.startMs,
                    endMs: max(segment.endMs, segment.startMs),
                    text: segment.text,
                    localeIdentifier: segment.localeIdentifier,
                    engine: .nemotron,
                    originDeviceId: configuration.deviceId
                )
            }
        guard !rows.isEmpty else { return }
        do {
            try await repository.append(rows)
        } catch {
            emit(.failed(String(describing: error)))
        }
    }

    private func emit(_ event: ASRTranscriptEvent) {
        continuation?.yield(event)
        if case .finished = event { continuation?.finish() }
    }

    private static func secondsSince(_ instant: ContinuousClock.Instant) -> Double {
        let elapsed = instant.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

