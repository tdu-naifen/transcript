import Foundation

/// Maps a playback position to the transcript line that should be highlighted
/// (UI.md §3: "the line currently being played is visually highlighted").
public enum TranscriptPlaybackPosition {
    /// Index of the last line whose `startMs` is at or before `positionMs`. `utterances`
    /// is assumed sorted ascending by `startMs` (the detail screen's forward render
    /// order). Returns `nil` before the first line starts.
    public static func currentIndex(utterances: [Utterance], atMs positionMs: Int) -> Int? {
        var result: Int?
        for (index, utterance) in utterances.enumerated() {
            guard utterance.startMs <= positionMs else { break }
            result = index
        }
        return result
    }
}
