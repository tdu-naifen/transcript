import Foundation
// Transcript adaptation: retain immutable preparation policy with same-run diagnostics.

/// Cacheable result of deterministic segmentation and embedding extraction.
///
/// Pass it to `OfflineDiarizerManager.cluster(_:)` to re-run clustering without repeating
/// model inference.
@available(macOS 14.0, iOS 17.0, *)
public struct PreparedDiarization: Sendable {
    let audioSource: AudioSampleSource

    let segmentation: SegmentationOutput

    let timedEmbeddings: [TimedEmbedding]

    let audioLoadingSeconds: TimeInterval

    let segmentationSeconds: TimeInterval

    let embeddingExtractionSeconds: TimeInterval

    let prepareWallSeconds: TimeInterval

    let evidenceConfiguration: OfflineDiarizerConfig

    init(audioSource: AudioSampleSource, segmentation: SegmentationOutput,
         timedEmbeddings: [TimedEmbedding], audioLoadingSeconds: TimeInterval,
         segmentationSeconds: TimeInterval, embeddingExtractionSeconds: TimeInterval,
         prepareWallSeconds: TimeInterval, evidenceConfiguration: OfflineDiarizerConfig = .default) {
        self.audioSource = audioSource
        self.segmentation = segmentation
        self.timedEmbeddings = timedEmbeddings
        self.audioLoadingSeconds = audioLoadingSeconds
        self.segmentationSeconds = segmentationSeconds
        self.embeddingExtractionSeconds = embeddingExtractionSeconds
        self.prepareWallSeconds = prepareWallSeconds
        self.evidenceConfiguration = evidenceConfiguration
    }

    public var embeddingCount: Int { timedEmbeddings.count }

    public var segmentationChunkCount: Int { segmentation.numChunks }
}
