import AVFoundation
import Foundation

/// The single format the whole capture pipeline speaks: 16 kHz mono Float32,
/// which is what Nemotron requires (PLAN §4.1).
public enum AudioCaptureFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount: AVAudioChannelCount = 1

    /// A fresh format instance. `AVAudioFormat` is not `Sendable`, so this is a
    /// factory rather than a shared constant.
    public static func makeProcessingFormat() -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            preconditionFailure("16 kHz mono Float32 is always representable")
        }
        return format
    }
}

/// Chunk size the ASR consumer is fed with.
///
/// The CoreML port of Nemotron currently exposes only the 2240 ms tier, but the model
/// card lists 80–1120 ms tiers that PLAN §9.5 wants once they are converted — so this
/// is a parameter, not a constant.
public struct AudioChunkTier: Sendable, Hashable, Codable {
    public let milliseconds: Int

    public init(milliseconds: Int) {
        self.milliseconds = max(1, milliseconds)
    }

    /// The only tier the current CoreML port supports (PLAN §4.1).
    public static let nemotron2240ms = AudioChunkTier(milliseconds: 2240)

    public func frameCount(sampleRate: Double = AudioCaptureFormat.sampleRate) -> Int {
        max(1, Int((Double(milliseconds) / 1000 * sampleRate).rounded()))
    }
}

public struct AudioCaptureConfiguration: Sendable {
    public var tier: AudioChunkTier
    public var sampleRate: Double
    /// UI meter refresh interval. The meter must not consume the ASR chunk stream.
    public var levelInterval: TimeInterval
    public var tapBufferSize: AVAudioFrameCount
    public var audioBitRate: Int
    /// How much audio a crash can cost: fMP4 fragments land on disk whole, at this cadence.
    public var segmentSeconds: Double

    public init(
        tier: AudioChunkTier = .nemotron2240ms,
        sampleRate: Double = AudioCaptureFormat.sampleRate,
        levelInterval: TimeInterval = 1.0 / 20,
        tapBufferSize: AVAudioFrameCount = 4096,
        audioBitRate: Int = 32_000,
        segmentSeconds: Double = 5
    ) {
        self.tier = tier
        self.sampleRate = sampleRate
        self.levelInterval = levelInterval
        self.tapBufferSize = tapBufferSize
        self.audioBitRate = audioBitRate
        self.segmentSeconds = segmentSeconds
    }
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case invalidInputFormat
    case converterUnavailable
    case bufferAllocationFailed
    case conversionFailed(String)
    case writerUnavailable(String)
    case writerFailed(String)
    case notRecording
    case alreadyRecording
    case invalidAudioFileName(String)
    case audioFileMissing(String)
}
