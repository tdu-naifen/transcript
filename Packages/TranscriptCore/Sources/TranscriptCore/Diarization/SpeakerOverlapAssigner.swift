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
    ///   overlaps the utterance or multiple speakers have the same maximal overlap.
    public static func speakerIndex(
        utteranceStartMs: Int,
        utteranceEndMs: Int,
        segments: [DiarizerSegment]
    ) -> Int? {
        let start = Double(utteranceStartMs) / 1000
        let end = Double(utteranceEndMs) / 1000
        var overlapBySpeaker: [Int: Double] = [:]
        for segment in segments {
            let overlapStart = max(start, Double(segment.startTime))
            let overlapEnd = min(end, Double(segment.endTime))
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }
            overlapBySpeaker[segment.speakerIndex, default: 0] += overlap
        }
        guard let bestOverlap = overlapBySpeaker.values.max() else { return nil }
        let winners = overlapBySpeaker.filter { $0.value == bestOverlap }
        return winners.count == 1 ? winners.first?.key : nil
    }
}
