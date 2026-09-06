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
                        Text("Default language for new meetings", tableName: "RecordingLanguage")
                    }
                    .accessibilityIdentifier("recordingLanguagePicker")
                    switch services.speechResources.state(for: services.recordingLocale) {
                    case .idle:
                        Button {
                            services.speechResources.prepare(locale: services.recordingLocale)
                        } label: {
                            Text("Prepare language", tableName: "RecordingLanguage")
                        }
                    case .preparing:
                        HStack {
                            ProgressView(value: services.speechResources.fractionCompleted(for: services.recordingLocale))
                            Text("Preparing Apple language resources…", tableName: "AppleSpeech")
                        }
                        Text("iOS manages the download. Preparation time varies.", tableName: "RecordingLanguage")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(role: .cancel) {
                            services.speechResources.cancel(locale: services.recordingLocale)
                        } label: {
                            Text("Cancel language setup", tableName: "RecordingLanguage")
                        }
                    case .ready:
                        Label {
                            Text("Apple language resources ready", tableName: "AppleSpeech")
                        } icon: { Image(systemName: "checkmark.circle") }
                    case .failed(let issue):
                        Text(issue.text).foregroundStyle(.secondary)
                            .accessibilityIdentifier("languageResourceFailure")
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
                    Text("System uses the device language, not automatic language detection. Change the current meeting language using its globe menu.", tableName: "RecordingLanguage")
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
                    .pickerStyle(.menu)
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
            .onAppear {
                recordingLanguage = services.asrLanguage.promptKey
                services.speechResources.prepare(locale: services.recordingLocale)
            }
            .onChange(of: recordingLanguage) { _, language in
                services.asrLanguage = language == "auto" ? .auto : .locale(language)
                services.speechResources.prepare(locale: services.recordingLocale)
            }
        }
    }
}
