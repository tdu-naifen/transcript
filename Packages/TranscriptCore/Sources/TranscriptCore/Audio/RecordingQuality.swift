import Foundation

/// Archive quality, decoupled from the ASR input format (UI §5.1).
///
/// The ASR feed is always 16 kHz mono (`AudioCaptureFormat`, a hard Nemotron
/// requirement) regardless of this setting. This only changes what gets written to
/// the archived M4A: `.voice` reuses the same 16 kHz mono stream the ASR engine
/// consumes (today's behavior, zero extra cost); `.highFidelity` archives a second,
/// independently-resampled stream at a higher sample rate, so a future re-transcribe
/// is not permanently capped at 16 kHz.
public enum RecordingQuality: String, Sendable, Codable, CaseIterable {
    case voice
    case highFidelity

    public var archiveSampleRate: Double {
        switch self {
        case .voice: AudioCaptureFormat.sampleRate
        case .highFidelity: 44_100
        }
    }

    public var archiveBitRate: Int {
        switch self {
        case .voice: 32_000
        case .highFidelity: 128_000
        }
    }
}
