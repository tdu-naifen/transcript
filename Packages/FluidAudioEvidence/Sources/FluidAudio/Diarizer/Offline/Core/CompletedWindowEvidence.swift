import Foundation

/// Original segmentation and extraction from exactly one complete real-audio window.
/// Rows remain bound to this invocation when retained in a later clustering cohort.
public struct CompletedWindowEvidence: Sendable {
    public struct Row: Sendable {
        public let id: UUID
        public let runID: UUID
        public let speakerIndex: Int
        public let startFrame: Int
        public let endFrame: Int
        public let frameWeights: [Float]
        public let embedding256: [Float]
        public let rho128: [Double]
        let original: TimedEmbedding

        init(_ value: TimedEmbedding, runID: UUID) {
            id = UUID()
            self.runID = runID
            speakerIndex = value.speakerIndex
            startFrame = value.startFrame
            endFrame = value.endFrame
            frameWeights = value.frameWeights
            embedding256 = value.embedding256
            rho128 = value.rho128
            original = value
        }
    }

    public let runID: UUID
    public let sampleCount: Int
    public let segmentation: SegmentationOutput
    public let rows: [Row]
    public let configuration: OfflineDiarizerConfig

    init(segmentation: SegmentationOutput, embeddings: [TimedEmbedding], configuration: OfflineDiarizerConfig) {
        let runID = UUID()
        self.runID = runID
        sampleCount = configuration.samplesPerWindow
        self.segmentation = segmentation
        rows = embeddings.map { Row($0, runID: runID) }
        self.configuration = configuration
    }
}

/// A new clustering invocation over exact original extraction rows, not segmentation replay.
public struct EvidenceCohortResult: Sendable {
    public let runID: UUID
    public let rowIDs: [UUID]
    public let assignments: [Int]
}
