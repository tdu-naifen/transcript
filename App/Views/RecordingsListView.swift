import SwiftUI
import TranscriptCore

struct RecordingsListView: View {
    let model: LibraryModel
    let services: AppServices
    @Binding var path: NavigationPath
    let isRecordingActive: () -> Bool
    @State private var pendingDeletion: Meeting?
    @Environment(\.calendar) private var calendar

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.errorMessage != nil {
                    LibraryErrorView(model: model)
                }
                if model.meetings.isEmpty {
                    if model.isLoading || (!model.hasLoaded && model.errorMessage == nil) {
                        ProgressView("library.loading")
                    } else if model.errorMessage == nil {
                        ContentUnavailableView(
                            "meetings.empty.title", systemImage: "waveform",
                            description: Text("meetings.empty.description")
                        )
                    }
                } else {
                    ForEach(dateGroups) { group in
                        Section {
                            ForEach(group.meetings) { meeting in
                                NavigationLink(value: meeting) {
                                    MeetingRow(
                                        meeting: meeting,
                                        participants: model.participants[meeting.id] ?? []
                                    )
                                }
                                .disabled(model.deletingIDs.contains(meeting.id))
                                .swipeActions(allowsFullSwipe: false) {
                                    Button(role: .destructive) { pendingDeletion = meeting } label: {
                                        Label("meetings.delete_local.action", systemImage: "trash")
                                    }
                                    .disabled(model.deletingIDs.contains(meeting.id))
                                }
                            }
                        } header: {
                            if let month = group.month {
                                Text(month, format: .dateTime.year().month(.wide))
                            } else {
                                Text(LocalizedStringKey(group.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: FloatingRecordButtonMetrics.listBottomClearance)
            }
            .navigationDestination(for: Meeting.self) { meeting in
                MeetingDetailView(
                    meeting: meeting,
                    audioURL: model.audioURL(for: meeting),
                    services: services,
                    isRecordingActive: isRecordingActive(),
                    onMeetingRenamed: { Task { await model.reload() } }
                )
            }
            .navigationTitle("meetings.title")
            .confirmationDialog(
                "meetings.delete_local.title",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { meeting in
                Button("meetings.delete_local.action", role: .destructive) {
                    pendingDeletion = nil
                    Task { await model.delete(meeting) }
                }
                Button("common.cancel", role: .cancel) { pendingDeletion = nil }
            } message: { meeting in
                Text(meeting.title) + Text("\n") + Text("meetings.delete_local.scope")
            }
            .refreshable { await model.reload() }
            .task {
                await model.reload()
                openFixtureMeetingIfRequested()
            }
            .onChange(of: model.meetings) { _, _ in
                openFixtureMeetingIfRequested()
            }
        }
    }

    private struct DateGroup: Identifiable {
        let id: String
        var month: Date? = nil
        let meetings: [Meeting]
    }

    private var dateGroups: [DateGroup] {
        var today: [Meeting] = []
        var yesterday: [Meeting] = []
        var earlier: [Meeting] = []
        for meeting in model.meetings {
            if calendar.isDateInToday(meeting.startedAt) {
                today.append(meeting)
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                yesterday.append(meeting)
            } else {
                earlier.append(meeting)
            }
        }
        var groups: [DateGroup] = []
        if !today.isEmpty { groups.append(DateGroup(id: "meetings.today", meetings: today)) }
        if !yesterday.isEmpty { groups.append(DateGroup(id: "meetings.yesterday", meetings: yesterday)) }
        if earlier.count > 30 {
            let months = Dictionary(grouping: earlier) {
                calendar.dateInterval(of: .month, for: $0.startedAt)?.start
                    ?? calendar.startOfDay(for: $0.startedAt)
            }
            for month in months.keys.sorted(by: >) {
                groups.append(DateGroup(id: "month-\(month.timeIntervalSinceReferenceDate)", month: month, meetings: months[month] ?? []))
            }
        } else if !earlier.isEmpty {
            groups.append(DateGroup(id: "meetings.earlier", meetings: earlier))
        }
        return groups
    }

    private func openFixtureMeetingIfRequested() {
        #if DEBUG
        guard path.isEmpty,
              let id = UserDefaults.standard.string(forKey: "uiFixtureOpenMeetingId"),
              let meeting = model.meetings.first(where: { $0.id == id }) else { return }
        path.append(meeting)
        #endif
    }
}

/// Shared by the full library and Home's small, unfiltered recent-meetings list.
struct MeetingRow: View {
    let meeting: Meeting
    let participants: [Speaker]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(.headline)
                .foregroundStyle(Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255))
                .frame(width: 40, height: 40)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metadata }
                    VStack(alignment: .leading, spacing: 2) { metadata }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(participants.prefix(3)) { speaker in
                    HStack(spacing: 6) {
                        SpeakerDotsView(colorIndexes: [speaker.colorIndex])
                            .accessibilityHidden(true)
                        Text(speaker.resolvedName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if participants.count > 3 {
                    Text("meetings.more_participants \(participants.count - 3)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recordingRow")
    }

    @ViewBuilder private var metadata: some View {
        Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
        Text(Format.duration(milliseconds: meeting.durationMs)).monospacedDigit()
    }
}

struct LibraryErrorView: View {
    let model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(model.errorTitleKey), systemImage: "exclamationmark.triangle")
                .font(.headline)
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button("library.reload") { Task { await model.reload() } }
                .disabled(model.isLoading)
        }
        .accessibilityIdentifier("libraryError")
    }
}
