import SwiftUI
import TranscriptCore

struct SettingsView: View {
    let services: AppServices
    @Binding var path: NavigationPath
    @State private var models: ModelDownloadModel?
    @State private var localization = LocalizationManager.shared

    var body: some View {
        NavigationStack {
            List {
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

                Section("App Language") {
                    Picker("App Language", selection: $localization.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("appLanguagePicker")
                }

                Section("This device") {
                    LabeledContent("Device ID", value: services.deviceId)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LabeledContent("Audio folder", value: services.store.directory.lastPathComponent)
                }

                Section("Recording button") {
                    Button("Reset recording button position") {
                        FloatingRecordButton.resetPosition()
                    }
                    .accessibilityIdentifier("resetFloatingRecordButton")
                }
            }
            .navigationTitle(LocalizationManager.shared.text("Settings"))
            .scrollContentBackground(.hidden)
            .background(AppColors.settingsBackground)
            .task {
                if models == nil { models = ModelDownloadModel(services: services) }
                models?.observe()
            }
        }
    }
}

private struct ModelRow: View {
    @Bindable var model: ModelDownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: model.statusText)

            if case .downloading = model.state {
                ProgressView(value: model.state.fraction)
                Button("Cancel", role: .destructive) { Task { await model.cancel() } }
                    .accessibilityIdentifier("cancelModelDownloadButton")
            } else if model.isInstalled {
                Button("Remove download", role: .destructive) { Task { await model.remove() } }
                    .accessibilityIdentifier("removeModelButton")
            } else {
                Button("Download model") { Task { await model.download() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.filledControl)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("downloadModelButton")
            }
        }
    }
}
