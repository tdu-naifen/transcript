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
                case .voiceprints: MacVoiceprintsView()
                case .analysis: MacMeetingsView()
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
                    workspace.showingConnection = true
                } label: {
                    HStack(spacing: 6) {
                        MacPhoneConnectionIcon(
                            isConnected: workspace.bonjour.pairing.isConnected,
                            isWorking: workspace.meetingCopy.progress != nil || workspace.bonjour.pairing.state == .negotiating,
                            size: 16
                        )
                        Text(workspace.bonjour.pairing.isConnected ? String(localized: "Connected") : String(localized: "Not connected"))
                    }
                }
                .help("Discovery is separate from a trusted connection.")
                .accessibilityIdentifier("macConnectionToolbar")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("macSettingsButton")
            }
        }
        .sheet(isPresented: $workspace.showingConnection) {
            VStack {
                HStack {
                    Spacer()
                    Button("Done") { workspace.showingConnection = false }
                        .accessibilityIdentifier("macConnectionDone")
                }.padding()
                MacConnectionView()
            }
            .frame(minWidth: 720, minHeight: 600)
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
            workspace.processing.onPublished = { [weak library = workspace.library] _ in
                await library?.load()
            }
            await workspace.startServices()
            await workspace.library.load()
            do {
                workspace.processing.configure(context: try await workspace.library.processingContext())
            } catch { workspace.processing.report(error) }
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
        .onChange(of: workspace.library.revision) {
            if !workspace.showingSamples, let selected = workspace.selectedMeetingID,
               !workspace.library.items.contains(where: { $0.id == selected }) {
                workspace.player.unload()
            }
            if !workspace.showingSamples { workspace.selectFirstIfNeeded() }
        }
        .onChange(of: workspace.section) { _, section in
            if section != .meetings { workspace.player.unload() }
            if section != .analysis { workspace.analysisMeetingID = nil }
        }
        .onChange(of: workspace.bonjour.pairing.confirmation) { _, confirmation in
            if confirmation != nil { workspace.showingConnection = true }
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
