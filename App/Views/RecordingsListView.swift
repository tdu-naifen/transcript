import SwiftUI
import TranscriptCore

struct RecordingsListView: View {
    let model: LibraryModel

    var body: some View {
        NavigationStack {
            Group {
                if model.meetings.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text("Recordings you make appear here, newest first.")
                    )
                } else {
                    List {
                        ForEach(model.meetings) { meeting in
                            NavigationLink {
                                MeetingDetailView(
                                    meeting: meeting,
                                    audioURL: model.audioURL(for: meeting),
                                    database: model.database
                                )
                            } label: {
                                MeetingRow(meeting: meeting, colorIndexes: model.speakerColorIndexes[meeting.id] ?? [])
                            }
                        }
                        .onDelete { offsets in
                            let toDelete = offsets.map { model.meetings[$0] }
                            Task { for meeting in toDelete { await model.delete(meeting) } }
                        }
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .bottom) {
                        // Clears the floating record button (RootView), which floats
                        // outside the TabView and so contributes no safe area of its own.
                        Color.clear.frame(height: FloatingRecordButtonMetrics.listBottomClearance)
                    }
                }
            }
            .navigationTitle("录音")
            .refreshable { await model.reload() }
            .task { await model.reload() }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let colorIndexes: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text(Format.duration(milliseconds: meeting.durationMs))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !colorIndexes.isEmpty {
                SpeakerDotsView(colorIndexes: colorIndexes)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Stable per-speaker color dots (UI.md §4.4): the color survives renaming and is
/// consistent across every meeting the speaker appears in.
private struct SpeakerDotsView: View {
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
