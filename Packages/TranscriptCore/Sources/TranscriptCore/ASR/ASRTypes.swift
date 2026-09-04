import Foundation

/// A transcript line. The same `id` is reused as the line grows, so a view can
/// replace in place instead of appending duplicates.
public struct ASRSegment: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let startMs: Int
    public let endMs: Int
    /// BCP-47 tag the model emitted in `auto` mode, or the requested language.
    public let localeIdentifier: String?
    public let isFinal: Bool

    public init(
        id: String,
        text: String,
        startMs: Int,
        endMs: Int,
        localeIdentifier: String?,
        isFinal: Bool
    ) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.localeIdentifier = localeIdentifier
        self.isFinal = isFinal
    }
}

/// What the engine reports once its models are resident.
public struct ASREngineInfo: Sendable, Hashable {
    public let language: ASRLanguage
    public let loadSeconds: Double

    public init(language: ASRLanguage, loadSeconds: Double) {
        self.language = language
        self.loadSeconds = loadSeconds
    }

    /// FluidAudio's default `MLModelConfiguration` targets the ANE
    /// (`.cpuAndNeuralEngine`); there is no per-op compute-plan introspection to
    /// report against here any more, so this is a fixed label for the UI badge.
    public var dominantComputeUnit: String { "Neural Engine" }
}

public enum ASRTranscriptEvent: Sendable {
    case ready(ASREngineInfo)
    case segment(ASRSegment)
    case failed(String)
    case finished
}

