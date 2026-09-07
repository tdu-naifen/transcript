import XCTest
@testable import FluidAudio
@testable import TranscriptCore

/// Only fixtures synthesize SDK preparation. Shipping code can only obtain a
/// payload from clusterWithEvidence; it cannot construct one from public replay.
enum DynamicSpeakerTestHarness {
    static func reconstruct(_ capture: MaskCapture, assignments: [ChunkEmbedding]) throws -> EvidenceTimeline {
        // Retain malformed geometry checks from the prototype before building fixture rows.
        guard capture.sampleCount > 0, capture.sampleCount <= EvidenceAdapter.maxSamples,
              capture.framesPerWindow > 0,
              capture.windows.count == (capture.sampleCount + 31_999) / 32_000,
              capture.windows.enumerated().allSatisfy({ $0.element.index == $0.offset && $0.element.offsetSamples == $0.offset * 32_000 })
        else { throw EvidenceError.geometry }
        let logs: [[[Float]]] = capture.windows.map { window in
            window.slots.map { slots in
                guard let slots, let index = EvidenceAdapter.powerset.firstIndex(of: slots) else {
                    return Array(repeating: 0, count: 8)
                }
                return (0..<8).map { $0 == index ? 0 : -10 }
            }
        }
        let weights: [[[Float]]] = capture.windows.map { window in
            window.slots.map { slots in (0..<3).map { slots?.contains($0) == true ? 1 : 0 } }
        }
        let segmentation = SegmentationOutput(
            logProbs: logs, speakerWeights: weights, numChunks: capture.windows.count,
            numFrames: capture.framesPerWindow, numSpeakers: 3,
            chunkOffsets: capture.windows.map { Double($0.offsetSamples) / 16_000 },
            frameDuration: 10 / Double(capture.framesPerWindow))
        let embeddings: [TimedEmbedding] = try assignments.map { assignment in
            guard capture.windows.indices.contains(assignment.chunkIndex) else { throw EvidenceError.assignments }
            let window = capture.windows[assignment.chunkIndex]
            let mask = EvidenceAdapter.embeddingFrames(window, slot: assignment.speakerIndex)
            return TimedEmbedding(
                chunkIndex: assignment.chunkIndex, speakerIndex: assignment.speakerIndex,
                startFrame: mask.first ?? 0, endFrame: mask.last ?? 0,
                frameWeights: window.slots.indices.map { mask.contains($0) ? 1 : 0 },
                startTime: assignment.startTimeSeconds, endTime: assignment.endTimeSeconds,
                embedding256: assignment.embedding256, rho128: assignment.rho128)
        }
        let prepared = PreparedDiarization(
            audioSource: CountOnlyAudio(sampleCount: capture.sampleCount), segmentation: segmentation,
            timedEmbeddings: embeddings, audioLoadingSeconds: 0, segmentationSeconds: 0,
            embeddingExtractionSeconds: 0, prepareWallSeconds: 0)
        let labels = assignments.map { (Int($0.speakerId.dropFirst()) ?? 0) - 1 }
        return try EvidenceAdapter.reconstruct(OfflineDiarizationEvidence(
            prepared: prepared, assignments: labels, configuration: EvidenceAdapter.configuration(), clusteringSeconds: 0))
    }

    private struct CountOnlyAudio: AudioSampleSource {
        let sampleCount: Int
        func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
            XCTFail("Fixture must not run model inference.")
        }
    }
}

enum SDKDiagnosticHarness {
    static func reconstruct(_ prepared: PreparedDiarization, result: DiarizationResult, sampleCount: Int) throws -> EvidenceTimeline {
        guard sampleCount == prepared.audioSource.sampleCount, let assignments = result.chunkEmbeddings,
              assignments.count == prepared.timedEmbeddings.count else { throw EvidenceError.assignments }
        for (a, b) in zip(assignments, prepared.timedEmbeddings) {
            guard a.chunkIndex == b.chunkIndex, a.speakerIndex == b.speakerIndex,
                  a.startTimeSeconds == b.startTime, a.endTimeSeconds == b.endTime,
                  a.embedding256 == b.embedding256, a.rho128 == b.rho128 else { throw EvidenceError.assignments }
        }
        return try EvidenceAdapter.reconstruct(OfflineDiarizationEvidence(
            prepared: prepared, assignments: assignments.map { (Int($0.speakerId.dropFirst()) ?? 0) - 1 },
            configuration: EvidenceAdapter.configuration(), clusteringSeconds: 0))
    }
}
