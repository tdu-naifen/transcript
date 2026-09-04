import SwiftUI
import TranscriptCore

struct SettingsView: View {
    let deviceId: String
    let audioDirectory: URL

    var body: some View {
        NavigationStack {
            List {
                Section("Capture") {
                    LabeledContent("Format", value: "M4A · AAC")
                    LabeledContent("Sample rate", value: "16 kHz mono")
                    LabeledContent("ASR chunk", value: "\(AudioChunkTier.nemotron2240ms.milliseconds) ms")
                }
                Section("This device") {
                    LabeledContent("Device ID", value: deviceId)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LabeledContent("Audio folder", value: audioDirectory.lastPathComponent)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
