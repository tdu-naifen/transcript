import FluidAudio
import Foundation

/// Measured cost of transcribing a fixed buffer, per PLAN §8 S1.
public struct ASRBenchmarkResult: Sendable {
    public let language: ASRLanguage
    public let detectedLanguage: String?
    public let loadSeconds: Double
    public let audioSeconds: Double
    public let inferenceSeconds: Double
    public let chunkLatenciesMs: [Double]
    public let baselineFootprintBytes: Int64?
    public let peakFootprintBytes: Int64?
    public let transcript: String
    public let segments: [ASRSegment]
    public let tokenCount: Int

    /// Inference wall time ÷ audio duration. Below 1.0 means it keeps up with live audio.
    public var realTimeFactor: Double {
        audioSeconds > 0 ? inferenceSeconds / audioSeconds : 0
    }

    public func latencyPercentile(_ percentile: Double) -> Double {
        guard !chunkLatenciesMs.isEmpty else { return 0 }
        let sorted = chunkLatenciesMs.sorted()
        let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// How often each locale was seen across segments, for auto-detect runs.
    public var detectedLocales: [String: Int] {
        segments.reduce(into: [:]) { counts, segment in
            guard let locale = segment.localeIdentifier else { return }
            counts[locale, default: 0] += 1
        }
    }
}

public enum ASRBenchmark {
    /// Loads the FluidAudio manager from `modelDirectory` and streams `samples`
    /// through it one tier-aligned chunk at a time, timing each chunk exactly as the
    /// live path would see it.
    public static func run(
        engine: StreamingNemotronMultilingualAsrManager,
        modelDirectory: URL,
        samples: [Float],
        language: ASRLanguage = .auto,
        tier: AudioChunkTier = .nemotron2240ms,
        sampleRate: Double = AudioCaptureFormat.sampleRate,
        onChunk: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ASRBenchmarkResult {
        let loadStarted = ContinuousClock.now
        try await engine.loadModels(from: modelDirectory)
        let loadSeconds = secondsSince(loadStarted)

        await engine.reset()
        await engine.setLanguage(language.fixedLocaleIdentifier)

        let chunks = AudioFileLoader.chunks(from: samples, tier: tier, sampleRate: sampleRate)
        var segmenter = TranscriptSegmenter(defaultLocale: language.fixedLocaleIdentifier)

        let baseline = MemoryFootprint.current()
        var latencies: [Double] = []
        var segments: [ASRSegment] = []
        var deliveredTimingCount = 0
        let started = ContinuousClock.now

        for (index, chunk) in chunks.enumerated() where chunk.frameCount > 0 {
            let chunkStart = ContinuousClock.now
            _ = try await engine.process(samples: chunk.samples)
            latencies.append(secondsSince(chunkStart) * 1000)
            if language == .auto, let detected = await engine.detectedLanguage() {
                segmenter.updateDefaultLocale(detected)
            }
            let timings = await engine.getTokenTimings()
            let newTimings = Array(timings.dropFirst(deliveredTimingCount))
            deliveredTimingCount = timings.count
            segments.append(contentsOf: segmenter.consume(newTimings).finalized)
            onChunk?(index + 1, chunks.count)
        }

        let (text, allTimings) = try await engine.finishWithTokenTimings()
        let trailingTimings = Array(allTimings.dropFirst(deliveredTimingCount))
        segments.append(contentsOf: segmenter.consume(trailingTimings).finalized)
        if let trailing = segmenter.flush() { segments.append(trailing) }

        let elapsed = secondsSince(started)
        let stats = await engine.lastDecodeStats()

        return ASRBenchmarkResult(
            language: language,
            detectedLanguage: stats.detectedLanguage,
            loadSeconds: loadSeconds,
            audioSeconds: Double(samples.count) / sampleRate,
            inferenceSeconds: elapsed,
            chunkLatenciesMs: latencies,
            baselineFootprintBytes: baseline,
            peakFootprintBytes: MemoryFootprint.peak(),
            transcript: text,
            segments: segments,
            tokenCount: stats.tokenCount
        )
    }

    private static func secondsSince(_ instant: ContinuousClock.Instant) -> Double {
        let elapsed = instant.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

