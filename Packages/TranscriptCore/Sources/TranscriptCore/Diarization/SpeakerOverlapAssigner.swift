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
    /// Resolve slots to persistent identities before deciding whether a turn is mixed.
    public static func speakerID(
        utteranceStartMs: Int, utteranceEndMs: Int,
        segments: [DiarizerSegment], identitiesBySlot: [Int: String]
    ) -> String? {
        let start = Double(utteranceStartMs) / 1000
        let end = Double(utteranceEndMs) / 1000
        var identities: Set<String> = []
        for segment in segments where min(end, Double(segment.endTime)) > max(start, Double(segment.startTime)) {
            guard let identity = identitiesBySlot[segment.speakerIndex] else { return nil }
            identities.insert(identity)
        }
        return identities.count == 1 ? identities.first : nil
    }

    /// - Returns: The speaker index when exactly one speaker overlaps the utterance,
    ///   or `nil` when the interval is unvoiced or spans multiple speakers.
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
        return overlapBySpeaker.count == 1 ? overlapBySpeaker.keys.first : nil
    }

    public static func unassignedCount(in utterances: [Utterance]) -> Int {
        utterances.count { $0.speakerId == nil }
    }
}
