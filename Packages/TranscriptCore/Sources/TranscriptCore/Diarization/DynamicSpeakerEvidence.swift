import Foundation
import FluidAudio
import CoreML

public enum EvidenceError: Error, Equatable {
    case bounds, geometry, outputShape, assignments, unsupportedPolicy
}

public enum Abstention: String, Codable, Hashable, Sendable {
    case unverifiedReplay, unsupportedSlot, conflictingIdentity, ambiguousLogits, uncovered
}

public struct EvidenceSpan: Equatable, Codable, Sendable {
    /// Half-open rational time: seconds = tick / ticksPerSecond.
    public let startTick: Int64
    public var endTick: Int64
    public let speakers: [String]
    /// Minimum unresolved multiplicity, not an exact count when logits/coverage are unknown.
    public let unknownSpeakerCount: Int
    public let reasons: Set<Abstention>
}

public struct EvidenceTimeline: Codable, Sendable {
    public let ticksPerSecond: Int64
    public let spans: [EvidenceSpan]
}

public struct MaskWindow: Sendable {
    public let index: Int
    public let offsetSamples: Int
    /// nil means ambiguous/nonfinite logits, [] means positively decoded silence.
    public let slots: [[Int]?]

    public init(index: Int, offsetSamples: Int, slots: [[Int]?]) {
        self.index = index
        self.offsetSamples = offsetSamples
        self.slots = slots
    }
}

public struct MaskCapture: Sendable {
    public let sampleCount: Int
    public let framesPerWindow: Int
    public let windows: [MaskWindow]

    public init(sampleCount: Int, framesPerWindow: Int, windows: [MaskWindow]) {
        self.sampleCount = sampleCount
        self.framesPerWindow = framesPerWindow
        self.windows = windows
    }
}

/// Internal fixture seam. Production only constructs this from the SDK's immutable
/// same-invocation payload, never by replaying segmentation or joining timestamps.
struct SameRunEvidence {
    let capture: MaskCapture
    let assignments: [ChunkEmbedding]
}

public enum EvidenceAdapter {
    /// Resource bound, not a speaker count or model-quality constraint.
    public static let maxSamples = 3_600 * 16_000
    public static let windowSamples = 160_000
    public static let stepSamples = 32_000
    public static let powerset = [[], [0], [1], [2], [0, 1], [0, 2], [1, 2], [0, 1, 2]]

    /// Reads logical indices, not raw contiguous Float pointers; honors MLMultiArray strides.
    /// Pinned community-1 has seven classes (no triple); eight is SDK-supported fixture form.
    public static func decode(_ output: MLMultiArray, offsets: [Int], firstIndex: Int) throws -> [MaskWindow] {
        let shape = output.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == offsets.count, (1...32).contains(shape[0]),
              (1...1_000).contains(shape[1]), [7, 8].contains(shape[2]) else {
            throw EvidenceError.outputShape
        }
        return offsets.enumerated().map { batch, offset in
            let frames: [[Int]?] = (0..<shape[1]).map { frame in
                let values = (0..<shape[2]).map {
                    output[[NSNumber(value: batch), NSNumber(value: frame), NSNumber(value: $0)]].doubleValue
                }
                guard values.allSatisfy(\.isFinite), let best = values.max(),
                      values.filter({ $0 == best }).count == 1,
                      let index = values.firstIndex(of: best) else { return nil }
                // Softmax/log-softmax preserves argmax. No marginalization or lowered threshold.
                return powerset[index]
            }
            return MaskWindow(index: firstIndex + batch, offsetSamples: offset, slots: frames)
        }
    }

    public static func configuration() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.exposeChunkEmbeddings = true
        config.exclusiveSegments = false
        // Count is inferred by unchanged AHC/VBx, never forced to forty.
        return config
    }

    /// Replayed masks alone cannot bind public assignments to a same-run local slot.
    /// This API is intentionally incapable of emitting a named identity.
    public static func reconstructPublicReplay(
        _ capture: MaskCapture, result: DiarizationResult
    ) throws -> EvidenceTimeline {
        try reconstruct(capture, assignments: result.chunkEmbeddings ?? [], verified: false)
    }

    static func reconstructSameRun(_ evidence: SameRunEvidence) throws -> EvidenceTimeline {
        try reconstruct(evidence.capture, assignments: evidence.assignments, verified: true)
    }

    public static func reconstruct(_ evidence: OfflineDiarizationEvidence) throws -> EvidenceTimeline {
        let config = evidence.configuration
        let preparation = evidence.preparationConfiguration
        guard preparation.samplesPerWindow == windowSamples, preparation.samplesPerStep == stepSamples,
              preparation.sampleRate == 16_000, preparation.embeddingExcludeOverlap,
              preparation.minSegmentDuration == 1, preparation.speechOnsetThreshold == 0.5,
              preparation.speechOffsetThreshold == 0.5,
              case .none = preparation.embeddingSkipStrategy
        else { throw EvidenceError.unsupportedPolicy }
        guard config.samplesPerWindow == windowSamples, config.samplesPerStep == stepSamples,
              config.sampleRate == 16_000, config.embeddingExcludeOverlap,
              config.minSegmentDuration == 1, config.speechOnsetThreshold == 0.5,
              config.speechOffsetThreshold == 0.5, config.clusteringThreshold == 0.6,
              config.clustering.numSpeakers == nil, config.clustering.minSpeakers == nil,
              config.clustering.maxSpeakers == nil, !config.zeroVoteReembed.enabled
        else { throw EvidenceError.unsupportedPolicy }
        let segmentation = evidence.segmentation
        guard evidence.sampleCount > 0, evidence.sampleCount <= maxSamples,
              (1...1_000).contains(segmentation.numFrames),
              segmentation.numChunks == (evidence.sampleCount + stepSamples - 1) / stepSamples,
              segmentation.numSpeakers == 3,
              segmentation.numChunks == segmentation.chunkOffsets.count,
              segmentation.numChunks == segmentation.speakerWeights.count,
              segmentation.numChunks == segmentation.logProbs.count,
              segmentation.frameDuration == 10.0 / Double(segmentation.numFrames)
        else { throw EvidenceError.geometry }
        let windows = try segmentation.speakerWeights.enumerated().map { chunk, weights in
            guard segmentation.chunkOffsets[chunk] == Double(chunk * stepSamples) / 16_000,
                  weights.count == segmentation.numFrames,
                  segmentation.logProbs[chunk].count == segmentation.numFrames
            else { throw EvidenceError.geometry }
            let slots: [[Int]?] = try weights.enumerated().map { frame, row in
                guard row.count == 3, row.allSatisfy({ $0 == 0 || $0 == 1 })
                else { throw EvidenceError.outputShape }
                let probabilities = segmentation.logProbs[chunk][frame]
                guard [7, 8].contains(probabilities.count) else { throw EvidenceError.outputShape }
                guard probabilities.allSatisfy(\.isFinite), let best = probabilities.max(),
                      probabilities.filter({ $0 == best }).count == 1,
                      let index = probabilities.firstIndex(of: best) else { return nil }
                let decoded = powerset[index]
                guard decoded == row.indices.filter({ row[$0] == 1 }) else { throw EvidenceError.outputShape }
                return decoded
            }
            return MaskWindow(index: chunk, offsetSamples: chunk * stepSamples, slots: slots)
        }
        let capture = MaskCapture(sampleCount: evidence.sampleCount,
                                  framesPerWindow: segmentation.numFrames, windows: windows)
        let assignments = try evidence.assignments.compactMap { row -> ChunkEmbedding? in
            guard windows.indices.contains(row.chunkIndex), (0..<3).contains(row.speakerIndex)
            else { throw EvidenceError.assignments }
            let mask = embeddingFrames(windows[row.chunkIndex], slot: row.speakerIndex)
            let actual = row.frameWeights.indices.filter { row.frameWeights[$0] > 0 }
            guard row.frameWeights.count == segmentation.numFrames,
                  row.frameWeights.allSatisfy({ $0 == 0 || $0 == 1 }),
                  !mask.isEmpty, actual == mask, row.startFrame == mask.first, row.endFrame == mask.last
            else { throw EvidenceError.assignments }
            guard let cluster = row.cluster, cluster >= 0 else { return nil }
            return ChunkEmbedding(speakerId: "S\(cluster + 1)", chunkIndex: row.chunkIndex, speakerIndex: row.speakerIndex,
                                  startTimeSeconds: row.startTime,
                                  endTimeSeconds: row.endTime, embedding256: row.embedding256, rho128: row.rho128)
        }
        return try reconstructSameRun(SameRunEvidence(capture: capture, assignments: assignments))
    }

    /// Mirror the installed extractor's 20% clean-mask gate and clean/base choice.
    /// This gate is not reduced to get more identities.
    static func embeddingFrames(_ window: MaskWindow, slot: Int) -> [Int] {
        let base = window.slots.indices.filter { window.slots[$0]?.contains(slot) == true }
        let clean = base.filter { window.slots[$0]?.count == 1 }
        guard Float(clean.count) >= Float(window.slots.count) * 0.2 else { return [] }
        let minimum = Int(ceil(1.0 / (10.0 / Double(window.slots.count))))
        return clean.count >= minimum ? clean : base
    }

    private struct Slot: Hashable { let chunk: Int; let local: Int }
    private struct FrameEvidence {
        var known: Set<String> = []
        var activeCount = 0
        var reasons: Set<Abstention> = []
    }

    private static func reconstruct(
        _ capture: MaskCapture, assignments: [ChunkEmbedding], verified: Bool
    ) throws -> EvidenceTimeline {
        let frames = capture.framesPerWindow
        guard capture.sampleCount > 0, capture.sampleCount <= maxSamples,
              (1...1_000).contains(frames), assignments.count <= (maxSamples / stepSamples) * 3 else { throw EvidenceError.bounds }
        let count = (capture.sampleCount + stepSamples - 1) / stepSamples
        guard capture.windows.count == count else { throw EvidenceError.geometry }
        for (index, window) in capture.windows.enumerated() {
            guard window.index == index, window.offsetSamples == index * stepSamples,
                  window.slots.count == frames,
                  window.slots.allSatisfy({ slots in
                      guard let slots else { return true }
                      return Set(slots).count == slots.count && slots.allSatisfy { (0..<3).contains($0) }
                  }) else { throw EvidenceError.geometry }
        }
        var mapping: [Slot: String] = [:]
        var seen: Set<Slot> = []
        var rejected: Set<Slot> = []
        for embedding in assignments {
            guard (0..<count).contains(embedding.chunkIndex), (0..<3).contains(embedding.speakerIndex)
            else { throw EvidenceError.assignments }
            let key = Slot(chunk: embedding.chunkIndex, local: embedding.speakerIndex)
            if !seen.insert(key).inserted { rejected.insert(key); continue }
            let id = embedding.speakerId
            let number = Int(id.dropFirst())
            let window = capture.windows[embedding.chunkIndex]
            let mask = embeddingFrames(window, slot: embedding.speakerIndex)
            guard id.first == "S", let number, number > 0, id == "S\(number)",
                  embedding.embedding256.count == 256,
                  embedding.embedding256.allSatisfy(\.isFinite),
                  embedding.embedding256.contains(where: { $0 != 0 }),
                  embedding.rho128.isEmpty || (embedding.rho128.count == 128 && embedding.rho128.allSatisfy(\.isFinite)),
                  let first = mask.first, let last = mask.last else {
                rejected.insert(key); continue
            }
            let offset = Double(window.offsetSamples) / 16_000
            let duration = 10.0 / Double(frames)
            guard embedding.startTimeSeconds.isFinite, embedding.endTimeSeconds.isFinite,
                  abs(embedding.startTimeSeconds - (offset + Double(first) * duration)) < 1e-9,
                  abs(embedding.endTimeSeconds - (offset + Double(last + 1) * duration)) < 1e-9
            else { rejected.insert(key); continue }
            mapping[key] = id
        }
        for key in rejected { mapping.removeValue(forKey: key) }

        let scale = Int64(frames)
        let end = Int64(capture.sampleCount) * scale
        // Same exact event intersection as the prototype, with only the at-most-five
        // covering windows resident in the sweep (no whole-recording event dictionary).
        var nextWindow = 0
        var active: [Int] = []
        var start: Int64 = 0
        var spans: [EvidenceSpan] = []
        while start < end {
            try Task.checkCancellation()
            while nextWindow < count, Int64(capture.windows[nextWindow].offsetSamples) * scale <= start {
                active.append(nextWindow)
                nextWindow += 1
            }
            active.removeAll { Int64(capture.windows[$0].offsetSamples + windowSamples) * scale <= start }
            var stop = nextWindow < count ? min(end, Int64(capture.windows[nextWindow].offsetSamples) * scale) : end
            let rows: [FrameEvidence] = active.map { index in
                let window = capture.windows[index]
                let offset = Int64(window.offsetSamples) * scale
                let frame = Int((start - offset) / Int64(windowSamples))
                let slots = window.slots[frame]
                stop = min(stop, offset + Int64((frame + 1) * windowSamples))
                var row = FrameEvidence()
                if let slots {
                    row.activeCount = slots.count
                    var collapsed = false
                    for slot in slots {
                        if verified, let id = mapping[Slot(chunk: window.index, local: slot)] {
                            if !row.known.insert(id).inserted { collapsed = true }
                        } else {
                            row.reasons.insert(verified ? .unsupportedSlot : .unverifiedReplay)
                        }
                    }
                    if collapsed {
                        // Two simultaneously active local slots cannot prove one shared identity.
                        row.known.removeAll()
                        row.reasons.insert(.conflictingIdentity)
                    }
                } else {
                    row.activeCount = 1
                    row.reasons.insert(.ambiguousLogits)
                }
                return row
            }
            var known = rows.first?.known ?? []
            var reasons: Set<Abstention> = []
            var required = 0
            for row in rows {
                known.formIntersection(row.known)
                reasons.formUnion(row.reasons)
                required = max(required, row.activeCount)
            }
            if rows.isEmpty { reasons.insert(.uncovered); required = 1 }
            if rows.contains(where: { $0.known != known }) { reasons.insert(.conflictingIdentity) }
            let unknown = max(required - known.count, reasons.isEmpty ? 0 : 1)
            let span = EvidenceSpan(startTick: start, endTick: stop, speakers: known.sorted(),
                                    unknownSpeakerCount: unknown, reasons: reasons)
            if let last = spans.last, last.endTick == start, last.speakers == span.speakers,
               last.unknownSpeakerCount == unknown, last.reasons == reasons {
                spans[spans.count - 1].endTick = stop
            } else { spans.append(span) }
            start = stop
        }
        return EvidenceTimeline(ticksPerSecond: scale * 16_000, spans: spans)
    }
}
