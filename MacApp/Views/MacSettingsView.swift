import SwiftUI

struct MacSettingsView: View {
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.colorScheme) private var scheme
    @AppStorage("mac.appearance") private var appearance = MacAppearance.system
    @State private var modelAvailability = MacAnalysisAvailability.checking

    var body: some View {
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
                LabeledContent("Transcription", value: String(localized: "Not configured"))
                LabeledContent("Speaker analysis", value: String(localized: "Not configured"))
                LabeledContent("Local AI", value: modelAvailability.message)
                Text("LLM Analysis uses Apple's on-device model. Apple Intelligence must be enabled. Importing and listening do not require this model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage & Privacy") {
                LabeledContent("Storage", value: String(localized: "This Mac only"))
                Text("Imported M4A files are copied into the app's local library. The original file is never changed. Samples are read-only and never saved.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Bonjour discovery is opt-in for this session. Pairing requires identity verification and matching codes. Meeting transfer is not available.")
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
        .frame(width: 560, height: 620)
        .navigationTitle("Settings")
        .accessibilityIdentifier("macSettingsForm")
        .task { modelAvailability = await MacFoundationModelsBackend().availability() }
    }
}
