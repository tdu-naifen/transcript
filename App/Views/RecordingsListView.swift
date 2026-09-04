import SwiftUI
import TranscriptCore

struct RecordingsListView: View {
    let model: LibraryModel
    let services: AppServices
    @Binding var path: NavigationPath
    let isRecordingActive: () -> Bool

    var body: some View {
        NavigationStack(path: $path) {
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
                            NavigationLink(value: meeting) {
                                MeetingRow(meeting: meeting, colorIndexes: model.speakerColorIndexes[meeting.id] ?? [])
                            }
                        }
                        .onDelete { offsets in
                            let toDelete = offsets.map { model.meetings[$0] }
                            Task { for meeting in toDelete { await model.delete(meeting) } }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .bottom) {
                        // Clears the floating record button (RootView), which floats
                        // outside the TabView and so contributes no safe area of its own.
                        Color.clear.frame(height: FloatingRecordButtonMetrics.listBottomClearance)
                    }
                }
            }
            .navigationDestination(for: Meeting.self) { meeting in
                MeetingDetailView(
                    meeting: meeting,
                    audioURL: model.audioURL(for: meeting),
                    services: services,
                    isRecordingActive: isRecordingActive()
                )
            }
            .navigationTitle("录音")
            .background(Color(red: 0.975, green: 0.97, blue: 0.96))
            .refreshable { await model.reload() }
            .task {
                await model.reload()
                openFixtureMeetingIfRequested()
            }
            .onChange(of: model.meetings) { _, _ in
                // `UIFixture` seeds meetings asynchronously after this task's own
                // `reload()` may already have run, so retry once the list updates.
                openFixtureMeetingIfRequested()
            }
        }
    }

    /// Simulator UI automation can't tap a row (no assistive-access API in this
    /// environment), so screenshotting the detail screen needs a scripted way in:
    /// `-uiFixtureOpenMeetingId fixture-meeting-review-90min` alongside `-uiFixture 1`.
    private func openFixtureMeetingIfRequested() {
        #if DEBUG
        guard path.isEmpty,
              let id = UserDefaults.standard.string(forKey: "uiFixtureOpenMeetingId"),
              let meeting = model.meetings.first(where: { $0.id == id }) else { return }
        path.append(meeting)
        #endif
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let colorIndexes: [Int]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.headline)
                .foregroundStyle(.red)
                .frame(width: 42, height: 42)
                .background(.red.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(Format.date(meeting.startedAt))
                    Text(Format.duration(milliseconds: meeting.durationMs))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !colorIndexes.isEmpty {
                    SpeakerDotsView(colorIndexes: colorIndexes)
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityIdentifier("recordingRow")
    }
}
