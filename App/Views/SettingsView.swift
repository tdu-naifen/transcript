import SwiftUI
import TranscriptCore

struct SettingsView: View {
    let services: AppServices
    @Binding var path: NavigationPath
    @State private var localization = LocalizationManager.shared
    @State private var recordingLanguage = "auto"

    static var modelDescription: String {
        LocalizationManager.shared.text(
            "Transcription uses Apple Speech on this device. iOS manages language resources and may download them the first time. No Nemotron download is required.",
            table: "AppleSpeech"
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text("Apple Speech")
                    } label: {
                        Text("Transcription engine", tableName: "AppleSpeech")
                    }
                    Picker(selection: $recordingLanguage) {
                        Text("System", tableName: "AppleSpeech").tag("auto")
                        Text("English (US)").tag("en-US")
                        Text("简体中文").tag("zh-CN")
                    } label: {
                        Text("Recording language", tableName: "AppleSpeech")
                    }
                    .accessibilityIdentifier("recordingLanguagePicker")
                    switch services.speechResources.state(for: services.recordingLocale) {
                    case .idle:
                        EmptyView()
                    case .preparing:
                        HStack {
                            ProgressView()
                            Text("Preparing Apple language resources…", tableName: "AppleSpeech")
                        }
                    case .ready:
                        Label {
                            Text("Apple language resources ready", tableName: "AppleSpeech")
                        } icon: { Image(systemName: "checkmark.circle") }
                    case .failed(let message):
                        Text(message).foregroundStyle(.secondary)
                        Button {
                            services.speechResources.prepare(locale: services.recordingLocale)
                        } label: {
                            Text("Retry Apple language setup", tableName: "AppleSpeech")
                        }
                    }
                } header: {
                    Text("Transcription model")
                } footer: {
                    Text(Self.modelDescription)
                        .accessibilityIdentifier("transcriptionModelDescription")
                }

                Section {
                    LabeledContent("Sortformer + CAM++", value: LocalizationManager.shared.text("On-device", table: "AppleSpeech"))
                    if services.speakerAnalysis.states.values.contains(.preparing) {
                        HStack {
                            ProgressView()
                            Text("Preparing animal recognition resources…", tableName: "AppleSpeech")
                        }
                    }
                    if let error = services.speakerAnalysis.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Animal identities", tableName: "AppleSpeech")
                } footer: {
                    Text("Voiceprint resources are prepared separately from Apple Speech. Animal identities stay on this device.", tableName: "AppleSpeech")
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
            .onAppear { recordingLanguage = services.asrLanguage.promptKey }
            .onChange(of: recordingLanguage) { _, language in
                services.asrLanguage = language == "auto" ? .auto : .locale(language)
            }
        }
    }
}
