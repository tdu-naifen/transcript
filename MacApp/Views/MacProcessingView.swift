import SwiftUI

struct MacProcessingView: View {
    @Environment(MacWorkspace.self) private var workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("ON YOUR MAC").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Text("Let your Mac take it from here.").font(.system(size: 27, weight: .semibold))
                Text("Connection, processing, and result delivery are separate states.")
                    .foregroundStyle(.secondary)
                if workspace.library.isImporting {
                    MacInfoCard {
                        ProgressView("Importing audio…")
                        Text("Copying and verifying the original recording before saving it to your library.")
                            .foregroundStyle(.secondary)
                    }
                }
                MacInfoCard {
                    Label("No processing jobs", systemImage: "clock")
                        .font(.headline)
                    Text("Imported recordings are ready to play. Automatic transcription and speaker analysis are not configured; on-demand chat and cited analysis are available in LLM Analysis.")
                        .foregroundStyle(.secondary)
                }
                MacInfoCard {
                    HStack {
                        Label("Model resources", systemImage: "cpu")
                            .font(.headline)
                        Spacer()
                        MacStatusLabel(title: "Not configured", color: .orange)
                    }
                    Text("Your saved recordings remain available even when models are not ready.")
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Model Settings") }
                }
                Button("View Meetings") { workspace.section = .meetings }
                    .buttonStyle(MacBrandButtonStyle())
            }
            .padding(36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Processing")
    }
}

struct MacInfoCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(23)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6))
            }
    }
}
