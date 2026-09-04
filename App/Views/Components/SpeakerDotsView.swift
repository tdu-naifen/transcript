import SwiftUI
import TranscriptCore

/// Stable per-speaker color dots (UI.md §4.4): the color survives renaming and is
/// consistent across every meeting the speaker appears in. Shared by the recordings
/// list and the meeting detail header.
struct SpeakerDotsView: View {
    let colorIndexes: [Int]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(colorIndexes.enumerated()), id: \.offset) { _, colorIndex in
                Circle()
                    .fill(Color.speaker(colorIndex: colorIndex))
                    .frame(width: 8, height: 8)
            }
        }
    }
}
