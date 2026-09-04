import Foundation

/// Share-of-talk percentages for the meeting-detail participants list (UI.md §3:
/// "Alex 42%"). Pure function over already-fetched utterances so both the iPhone
/// detail screen and any future Mac tooling can reuse it.
public enum SpeakerTalkShare {
    /// Percentage of total spoken duration attributed to each speaker in `speakerIds`,
    /// rounded independently (so the set need not sum to exactly 100). Utterances with
    /// no `speakerId`, or a `speakerId` outside `speakerIds`, still count toward the
    /// total but are not attributed to anyone.
    public static func percentages(utterances: [Utterance], speakerIds: [String]) -> [String: Int] {
        var durationsById: [String: Int] = [:]
        var total = 0
        for utterance in utterances {
            let duration = max(0, utterance.endMs - utterance.startMs)
            total += duration
            guard let speakerId = utterance.speakerId else { continue }
            durationsById[speakerId, default: 0] += duration
        }
        guard total > 0 else {
            return Dictionary(uniqueKeysWithValues: speakerIds.map { ($0, 0) })
        }
        return Dictionary(uniqueKeysWithValues: speakerIds.map { id in
            (id, Int((Double(durationsById[id] ?? 0) / Double(total) * 100).rounded()))
        })
    }
}
