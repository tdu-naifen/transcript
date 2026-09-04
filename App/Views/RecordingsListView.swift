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
                    List(model.meetings) { meeting in
                        NavigationLink {
                            MeetingDetailView(
                                meeting: meeting,
                                audioURL: model.audioURL(for: meeting),
                                database: model.database
                            )
                        } label: {
                            MeetingRow(meeting: meeting)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recordings")
            .refreshable { await model.reload() }
            .task { await model.reload() }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

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
            StatusChip(text: meeting.state.label, tint: meeting.state.tint)
        }
        .padding(.vertical, 4)
    }
}
