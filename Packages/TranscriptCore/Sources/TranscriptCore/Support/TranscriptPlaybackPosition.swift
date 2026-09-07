import Foundation

/// Maps a playback position to the transcript line that should be highlighted.
public enum TranscriptPlaybackPosition {
    /// Index of the last line whose `startMs` is at or before `positionMs`. `utterances`
    /// is assumed sorted ascending by `startMs` (the detail screen's forward render
    /// order). Returns `nil` before the first line starts. Lookup is O(log n).
    public static func currentIndex(utterances: [Utterance], atMs positionMs: Int) -> Int? {
        var lower = 0
        var upper = utterances.count
        // Find the first strictly later start, including every duplicate at the position.
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if utterances[middle].startMs <= positionMs {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == 0 ? nil : lower - 1
    }
}
