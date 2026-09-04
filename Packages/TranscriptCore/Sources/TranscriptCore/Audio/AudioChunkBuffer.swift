import Foundation

/// A fixed-size slice of 16 kHz mono audio, in capture order.
///
/// `index` and `startFrame` are assigned by ``AudioChunkBuffer`` and restart at 0 for
/// every recording, so a consumer can detect gaps and reordering without a clock.
public struct AudioChunk: Sendable, Hashable {
    public let index: Int
    public let startFrame: Int
    public let sampleRate: Double
    public let samples: [Float]
    /// Last chunk of a recording. It may be shorter than the tier, or empty when the
    /// recording ended exactly on a tier boundary.
    public let isFinal: Bool

    public init(index: Int, startFrame: Int, sampleRate: Double, samples: [Float], isFinal: Bool) {
        self.index = index
        self.startFrame = startFrame
        self.sampleRate = sampleRate
        self.samples = samples
        self.isFinal = isFinal
    }

    public var frameCount: Int { samples.count }

    public var startMs: Int { Int((Double(startFrame) / sampleRate * 1000).rounded()) }

    public var durationMs: Int { Int((Double(samples.count) / sampleRate * 1000).rounded()) }
}

/// Accumulates resampled audio and cuts it into tier-aligned chunks.
///
/// Pure value logic with no audio device involved, so chunk alignment is testable
/// without a microphone.
public struct AudioChunkBuffer: Sendable {
    public let frameCount: Int
    public let sampleRate: Double

    private var pending: [Float] = []
    private var nextIndex = 0
    private var emittedFrames = 0

    public init(
        tier: AudioChunkTier = .nemotron2240ms,
        sampleRate: Double = AudioCaptureFormat.sampleRate
    ) {
        self.sampleRate = sampleRate
        self.frameCount = tier.frameCount(sampleRate: sampleRate)
    }

    public init(frameCount: Int, sampleRate: Double = AudioCaptureFormat.sampleRate) {
        self.sampleRate = sampleRate
        self.frameCount = max(1, frameCount)
    }

    /// Frames handed to the buffer so far, emitted or still pending.
    public var totalFrameCount: Int { emittedFrames + pending.count }

    public var pendingFrameCount: Int { pending.count }

    public var nextChunkIndex: Int { nextIndex }

    /// Returns every whole chunk that just became available, in order.
    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        guard pending.count >= frameCount else { return [] }

        var chunks: [AudioChunk] = []
        var offset = 0
        while pending.count - offset >= frameCount {
            chunks.append(AudioChunk(
                index: nextIndex,
                startFrame: emittedFrames,
                sampleRate: sampleRate,
                samples: Array(pending[offset..<(offset + frameCount)]),
                isFinal: false
            ))
            nextIndex += 1
            emittedFrames += frameCount
            offset += frameCount
        }
        pending.removeFirst(offset)
        return chunks
    }

    /// The trailing partial chunk, or nil when the recording ended on a tier boundary.
    public mutating func flush() -> AudioChunk? {
        guard !pending.isEmpty else { return nil }
        let chunk = AudioChunk(
            index: nextIndex,
            startFrame: emittedFrames,
            sampleRate: sampleRate,
            samples: pending,
            isFinal: true
        )
        nextIndex += 1
        emittedFrames += pending.count
        pending.removeAll(keepingCapacity: false)
        return chunk
    }

    /// Always yields a terminating chunk, empty if nothing was pending, so a consumer
    /// can end its loop on `isFinal` instead of on stream termination.
    public mutating func finish() -> AudioChunk {
        if let chunk = flush() { return chunk }
        let chunk = AudioChunk(
            index: nextIndex,
            startFrame: emittedFrames,
            sampleRate: sampleRate,
            samples: [],
            isFinal: true
        )
        nextIndex += 1
        return chunk
    }
}
