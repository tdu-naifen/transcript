import SwiftUI
import TranscriptCore

struct SettingsView: View {
    let services: AppServices
    @State private var models: ModelDownloadModel?
    @State private var language: String

    init(services: AppServices) {
        self.services = services
        _language = State(initialValue: services.asrLanguage.promptKey)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Capture") {
                    LabeledContent("Format", value: "M4A · AAC")
                    LabeledContent("Sample rate", value: "16 kHz mono")
                    LabeledContent("ASR chunk", value: "\(AudioChunkTier.nemotron2240ms.milliseconds) ms")
                }

                Section {
                    if let models {
                        ModelRow(model: models)
                    }
                } header: {
                    Text("Transcription model")
                } footer: {
                    Text("Nemotron 3.5 ASR streaming, 2240 ms tier. Roughly 665 MB, downloaded once "
                        + "and kept in Application Support. Recording works without it.")
                }

                Section("Language") {
                    Picker("Spoken language", selection: $language) {
                        Text("Detect automatically").tag("auto")
                        ForEach(Self.commonLanguages, id: \.self) { identifier in
                            Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                                .tag(identifier)
                        }
                    }
                    .onChange(of: language) { _, new in
                        services.asrLanguage = new == "auto" ? .auto : .locale(new)
                    }
                }

                Section("This device") {
                    LabeledContent("Device ID", value: services.deviceId)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LabeledContent("Audio folder", value: services.store.directory.lastPathComponent)
                }
            }
            .navigationTitle("Settings")
            .task {
                if models == nil { models = ModelDownloadModel(services: services) }
                models?.observe()
            }
        }
    }

    /// A short list rather than all 128 prompts; `auto` covers the rest.
    private static let commonLanguages = [
        "en-US", "en-GB", "zh-CN", "zh-TW", "ja-JP", "ko-KR",
        "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ru-RU"
    ]
}

private struct ModelRow: View {
    @Bindable var model: ModelDownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: model.statusText)

            if case .downloading = model.state {
                ProgressView(value: model.state.fraction)
                Button("Cancel", role: .destructive) { Task { await model.cancel() } }
            } else if model.isInstalled {
                Button("Remove download", role: .destructive) { Task { await model.remove() } }
            } else {
                Button("Download model") { Task { await model.download() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            }
        }
    }
}
