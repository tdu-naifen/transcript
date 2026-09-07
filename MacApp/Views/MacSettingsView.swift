import SwiftUI

struct MacSettingsView: View {
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.colorScheme) private var scheme
    @AppStorage("mac.appearance") private var appearance = MacAppearance.system

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalSettings
            }
            Tab("Transcription Models", systemImage: "waveform") {
                MacProcessingView()
            }
            Tab("Backups", systemImage: "externaldrive.badge.timemachine") {
                ScrollView {
                    MacBackupSettingsView {
                        try await workspace.library.processingContext()
                    }
                    .padding(24)
                }
            }
        }
        .frame(width: 720, height: 680)
        .navigationTitle("Settings")
    }

    private var generalSettings: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(MacAppearance.allCases) { Text($0.title).tag($0) }
                }
                Text("The same deep blue as iPhone. Dark appearance uses a lighter blue for readable text and controls.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            }
            Section("Models") {
                Text("Manage transcription, diarization, speaker embedding models, and transcription language in Transcription Models.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Importing and listening do not require an AI model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage & Privacy") {
                LabeledContent("Storage", value: String(localized: "This Mac only"))
                Text("Imported M4A files are copied into the app's local library. The original file is never changed. Samples are read-only and never saved.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Discovery remembers your choice. Pairing verifies device identity. Open the connection control in the toolbar to manage your iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(LocalizedStringKey(workspace.showingSamples ? "Return to My Library" : "Show Sample Library")) {
                    workspace.setSamples(!workspace.showingSamples)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(MacTheme.settingsBackground(scheme: scheme))
        .accessibilityIdentifier("macSettingsForm")
    }
}
