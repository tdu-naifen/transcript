import Foundation

/// Immutable diagnostics from one prepared run and its actual clustering invocation.
/// No replay, inferred missing assignments, or post-reconstruction speaker labels.
/// Local adaptation of FluidAudio 0.15.6; see VENDOR-PROVENANCE.json.
@available(macOS 14.0, iOS 17.0, *)
public struct OfflineDiarizationEvidence: Sendable {
    public struct Assignment: Sendable {
        public let chunkIndex: Int
        public let speakerIndex: Int
        public let startFrame: Int
        public let endFrame: Int
        public let frameWeights: [Float]
        public let startTime: Double
        public let endTime: Double
        public let embedding256: [Float]
        public let rho128: [Double]
        public let cluster: Int?
    }

    public let runID: UUID
    public let sampleCount: Int
    public let segmentation: SegmentationOutput
    public let assignments: [Assignment]
    public let configuration: OfflineDiarizerConfig
    public let preparationConfiguration: OfflineDiarizerConfig
    public let preparationSeconds: TimeInterval
    public let clusteringSeconds: TimeInterval

    init(prepared: PreparedDiarization, assignments: [Int],
         configuration: OfflineDiarizerConfig, clusteringSeconds: TimeInterval) {
        runID = UUID()
        sampleCount = prepared.audioSource.sampleCount
        segmentation = prepared.segmentation
        self.configuration = configuration
        preparationConfiguration = prepared.evidenceConfiguration
        preparationSeconds = prepared.prepareWallSeconds
        self.clusteringSeconds = clusteringSeconds
        self.assignments = prepared.timedEmbeddings.enumerated().map { index, embedding in
            Assignment(
                chunkIndex: embedding.chunkIndex, speakerIndex: embedding.speakerIndex,
                startFrame: embedding.startFrame, endFrame: embedding.endFrame,
                frameWeights: embedding.frameWeights,
                startTime: embedding.startTime, endTime: embedding.endTime,
                embedding256: embedding.embedding256, rho128: embedding.rho128,
                cluster: assignments.count == prepared.timedEmbeddings.count && assignments[index] >= 0
                    ? assignments[index] : nil
            )
        }
    }
}
