import SwiftUI
import TranscriptCore

struct MacMeetingsView: View {
    @Environment(MacWorkspace.self) private var workspace
    @FocusState private var focusedMeetingID: String?

    var body: some View {
        @Bindable var workspace = workspace
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("All Meetings").font(.title2.bold())
                    Spacer()
                    Text(workspace.filteredItems.count, format: .number).foregroundStyle(.secondary)
                }
                .padding(20)
                if workspace.library.isImporting {
                    ProgressView("Importing audio…").controlSize(.small).padding(.bottom, 12)
                }
                if let message = workspace.library.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Library needs attention", systemImage: "exclamationmark.triangle")
                            .fontWeight(.medium)
                        Text(message).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("Retry") { Task { await workspace.library.load() } }
                            Button("Dismiss") { workspace.library.clearError() }
                        }
                    }
                    .padding(14)
                    .background(.orange.opacity(0.08))
                    .accessibilityIdentifier("macLibraryError")
                }
                List {
                    ForEach(workspace.filteredItems) { item in
                        Button {
                            workspace.selectedMeetingID = item.id
                            focusedMeetingID = item.id
                        } label: {
                            MacSelectionRow(isSelected: workspace.selectedMeetingID == item.id) {
                                MacMeetingRow(item: item, isSample: workspace.showingSamples)
                            }
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedMeetingID, equals: item.id)
                        .onKeyPress(.downArrow) { moveSelection(.down); return .handled }
                        .onKeyPress(.upArrow) { moveSelection(.up); return .handled }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .accessibilityIdentifier("macMeeting-\(item.id)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onMoveCommand(perform: moveSelection)
                .overlay {
                    if workspace.library.isLoading && workspace.items.isEmpty {
                        ProgressView("Loading meetings…")
                    } else if workspace.filteredItems.isEmpty && !workspace.search.isEmpty {
                        ContentUnavailableView.search(text: workspace.search)
                    }
                }
                Divider()
                Button(LocalizedStringKey(workspace.showingSamples ? "Return to My Library" : "Show Sample Library")) {
                    workspace.setSamples(!workspace.showingSamples)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.callout)
                .padding(16)
                .accessibilityIdentifier("macSampleToggle")
            }
            .frame(minWidth: 245, idealWidth: 264, maxWidth: 340)

            Group {
                if let item = workspace.selectedItem {
                    MacMeetingDetailView(item: item, isSample: workspace.showingSamples)
                        .id(item.id)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Meeting Library")
        .searchable(text: $workspace.search, placement: .toolbar, prompt: "Search meetings or content")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspace.showingImporter = true
                } label: {
                    Label("Import Audio…", systemImage: "square.and.arrow.down")
                }
                .disabled(workspace.library.isImporting)
                .accessibilityIdentifier("macImportAudio")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(LocalizedStringKey(workspace.search.isEmpty ? "Your meetings, ready for a bigger screen." : "No matching meetings"),
                  systemImage: workspace.search.isEmpty ? "waveform" : "magnifyingglass")
        } description: {
            Text(LocalizedStringKey(workspace.search.isEmpty
                 ? "Import an M4A recording to listen on this Mac, or explore the read-only sample library. iPhone transfer is not available yet."
                 : "Try a different word or clear the search."))
        } actions: {
            if workspace.search.isEmpty {
                Button("Import Audio…") { workspace.showingImporter = true }
                    .buttonStyle(MacBrandButtonStyle())
                    .disabled(workspace.library.isImporting)
                Button("Show Sample Library") { workspace.setSamples(true) }
            } else {
                Button("Clear Search") { workspace.search = "" }
            }
        }
        .onAppear { workspace.player.unload() }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        workspace.selectedMeetingID = MacListSelection.moved(
            workspace.selectedMeetingID, in: workspace.filteredItems.map(\.id), direction: direction
        )
        focusedMeetingID = workspace.selectedMeetingID
    }
}

private struct MacMeetingRow: View {
    let item: MacLibraryItem
    let isSample: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(item.meeting.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                Text(item.meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                Text("·")
                Text(DurationFormat.clock(seconds: Double(item.meeting.durationMs) / 1000))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(item.speakers.prefix(5)) { speaker in
                    Circle().fill(MacTheme.speaker(speaker.colorIndex)).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(LocalizedStringKey(isSample ? "Read-only sample" : "Saved on this Mac"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
