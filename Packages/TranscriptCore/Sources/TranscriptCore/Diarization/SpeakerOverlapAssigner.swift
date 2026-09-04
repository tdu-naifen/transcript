import FluidAudio
import Foundation

/// Assigns each ASR utterance a `speakerIndex` by maximal temporal overlap with
/// diarization segments. FluidAudio has no built-in ASR⊕diarization join, so this is it
/// (PLAN work item 3). Pure value logic — no I/O, no actors — so it is testable with
/// synthetic timings.
///
/// Both axes are absolute seconds from stream start: `Utterance.startMs`/`endMs` (as
/// milliseconds here) and `DiarizerSegment.startTime`/`endTime`.
public enum SpeakerOverlapAssigner {
    /// - Returns: The speaker index with the largest overlap, or `nil` if no segment
    ///   overlaps the utterance at all. Ties resolve to the lowest speaker index, so the
    ///   result never depends on `segments`' order.
    public static func speakerIndex(
        utteranceStartMs: Int,
        utteranceEndMs: Int,
        segments: [DiarizerSegment]
    ) -> Int? {
        let start = Double(utteranceStartMs) / 1000
        let end = Double(utteranceEndMs) / 1000
        var bestIndex: Int?
        var bestOverlap: Double = 0
        for segment in segments {
            let overlapStart = max(start, Double(segment.startTime))
            let overlapEnd = min(end, Double(segment.endTime))
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }
            if bestIndex == nil || overlap > bestOverlap
                || (overlap == bestOverlap && segment.speakerIndex < bestIndex!) {
                bestOverlap = overlap
                bestIndex = segment.speakerIndex
            }
        }
        return bestIndex
    }
}
