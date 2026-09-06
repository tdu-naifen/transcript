import SwiftUI
import UniformTypeIdentifiers

struct MacRootView: View {
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focusedSection: MacSection?

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 174, ideal: 184, max: 230)
        } detail: {
            Group {
                switch workspace.section ?? .meetings {
                case .meetings: MacMeetingsView()
                case .processing: MacProcessingView()
                case .connection: MacConnectionView()
                case .voiceprints: MacVoiceprintsView()
                case .analysis:
                    MacAnalysisView(meetingID: workspace.analysisMeetingID) { citation in
                        workspace.openReference(meetingID: citation.meetingID, utteranceID: citation.utteranceID)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if workspace.showingSamples && workspace.section == .meetings {
                    Label("Sample library", systemImage: "eye")
                        .foregroundStyle(.secondary)
                }
                Button {
                    workspace.section = .connection
                } label: {
                    Label(workspace.bonjour.pairing.connectedPeer == nil ? "Not connected" : "Connected", systemImage: "iphone")
                }
                .help("Discovery is separate from a trusted connection.")
                .accessibilityIdentifier("macConnectionToolbar")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("macSettingsButton")
            }
        }
        .fileImporter(
            isPresented: $workspace.showingImporter,
            allowedContentTypes: [.mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    workspace.importError = String(localized: "No audio file was selected.")
                    return
                }
                workspace.setSamples(false)
                Task {
                    await workspace.library.importAudio(from: url)
                    workspace.selectFirstIfNeeded()
                }
            case .failure(let error):
                workspace.importError = error.localizedDescription
            }
        }
        .alert("Unable to import audio", isPresented: Binding(
            get: { workspace.importError != nil },
            set: { if !$0 { workspace.importError = nil } }
        )) {
            Button("OK") { workspace.importError = nil }
        } message: {
            Text(workspace.importError ?? "")
        }
        .task {
            await workspace.library.load()
            workspace.selectFirstIfNeeded()
        }
        .alert("Reference unavailable", isPresented: Binding(
            get: { workspace.referenceError != nil },
            set: { if !$0 { workspace.referenceError = nil } }
        )) {
            Button("OK") { workspace.referenceError = nil }
        } message: {
            Text(workspace.referenceError ?? "")
        }
        .onChange(of: workspace.search) { workspace.selectFirstIfNeeded() }
        .onChange(of: workspace.section) { _, section in
            if section != .meetings { workspace.player.unload() }
            if section != .analysis { workspace.analysisMeetingID = nil }
        }
        .onChange(of: workspace.bonjour.pairing.confirmation) { _, confirmation in
            if confirmation != nil { workspace.section = .connection }
        }
        .onDisappear { workspace.player.unload() }
    }

    private var sidebar: some View {
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 0) {
                Text(verbatim: "Transcript").font(.title3.bold())
                Text(".").font(.title3.bold()).foregroundStyle(MacTheme.tint(scheme: scheme, contrast: contrast))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            List {
                Section("Workspace") {
                    ForEach(MacSection.allCases) { section in
                        Button {
                            workspace.section = section
                            focusedSection = section
                        } label: {
                            MacSelectionRow(isSelected: workspace.section == section) {
                                Label(section.title, systemImage: section.symbol)
                                    .foregroundStyle(workspace.section == section
                                        ? MacTheme.tint(scheme: scheme, contrast: contrast) : .primary)
                                    .padding(.vertical, 5)
                            }
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedSection, equals: section)
                        .onKeyPress(.downArrow) { moveSection(.down); return .handled }
                        .onKeyPress(.upArrow) { moveSection(.up); return .handled }
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .accessibilityIdentifier("macNav-\(section.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onMoveCommand(perform: moveSection)

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    workspace.section = .connection
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your iPhone", systemImage: "iphone")
                            .fontWeight(.medium)
                        Text(workspace.bonjour.pairing.connectedPeer?.name ?? String(localized: "Not connected"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Label("Saved meetings work offline", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private func moveSection(_ direction: MoveCommandDirection) {
        workspace.section = MacListSelection.moved(workspace.section, in: MacSection.allCases, direction: direction)
        focusedSection = workspace.section
    }
}
