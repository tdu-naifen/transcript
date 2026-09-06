import SwiftUI
import TranscriptCore

struct RecordView: View {
    @Bindable var model: RecorderModel
    let onCollapse: () -> Void
    let onStop: () -> Void
    var onStart: (() -> Void)? = nil
    var isStartingRecording = false
    @State private var isStarting = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            LinearGradient(
                colors: [FloatingRecordButton.accent.opacity(0.12), Color(uiColor: .systemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                collapseBar
                ScrollView {
                    VStack(spacing: 10) {
                        recordingHeader
                        if model.permission == .denied {
                            MicrophoneDeniedView()
                        } else {
                            LiveTranscriptView(model: model.transcription, scrollsInternally: false)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                                .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
                            if let notice = model.notice {
                                Text(notice)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .onTapGesture { model.dismissNotice() }
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
                .accessibilityIdentifier("recordingContentScrollView")
                if model.permission != .denied {
                    recordingControls
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        .task { await model.onAppear() }
        .alert(
            "Recording problem",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var recordingHeader: some View {
        VStack(spacing: 2) {
            adaptiveRow {
                Text("M4A")
                Text("\((model.recordingSampleRate / 1_000).formatted()) kHz")
                Label(
                    recordingStatusLabel,
                    systemImage: model.isProcessingTranscript && model.audioArchiveSaved
                        ? "checkmark.circle" : model.isActive ? "record.circle" : "mic"
                )
                    .foregroundStyle(model.isActive ? Color.red : AppColors.controlTint)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35), in: Capsule())

            Text(Format.clock(model.elapsed))
                .font(.largeTitle.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .monospacedDigit()
                .padding(.bottom, 8)
            if model.isProcessingTranscript {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finishing transcript…", tableName: "SpeakerProjection")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("recordingProcessingStatus")
            } else {
                LevelMeterView(level: model.level, isActive: model.phase == .recording)
                    .frame(height: 26)
            }
            adaptiveRow {
                Label("Apple Speech", systemImage: "waveform")
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                Menu {
                    Button { model.selectRecordingLanguage("auto") } label: {
                        Text("System language", tableName: "RecordingLanguage")
                    }
                    Button("English (US)") { model.selectRecordingLanguage("en-US") }
                    Button("简体中文") { model.selectRecordingLanguage("zh-CN") }
                } label: {
                    Label(model.recordingLanguageLabel, systemImage: "globe")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(model.phase != .recording)
                .accessibilityIdentifier("meetingLanguageMenu")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            Text("Language changes apply to subsequent audio only.", tableName: "RecordingLanguage")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meetingLanguageExplanation")
            if let locale = model.transcription.pendingLocale {
                VStack(alignment: .leading, spacing: 6) {
                    Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        .font(.caption.weight(.semibold))
                    if let failure = model.transcription.languageSwitchFailure {
                        Text(failure.text).font(.caption).foregroundStyle(.orange)
                        Button { model.transcription.retryLanguageSwitch() } label: {
                            Text("Retry language change", tableName: "RecordingLanguage")
                        }
                    } else {
                        ProgressView(value: model.transcription.languageProgress)
                        Text(model.transcription.languageReadyForBoundary
                             ? RecordingLanguageText.text("Language ready; waiting for the next audio chunk.")
                             : RecordingLanguageText.text("Preparing language; current recording continues."))
                            .font(.caption)
                    }
                    Button(role: .cancel) { model.transcription.cancelLanguageSwitch() } label: {
                        Text("Cancel language change", tableName: "RecordingLanguage")
                    }
                }
                .accessibilityIdentifier("meetingLanguagePreparation")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    private var collapseBar: some View {
        HStack(spacing: 12) {
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(Color.secondary.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Collapse recording")
            .accessibilityIdentifier("collapseRecordingButton")
            Spacer(minLength: 0)
            Label {
                Text("On-device", tableName: "AppleSpeech")
            } icon: { Image(systemName: "iphone") }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
    }

    private var recordingControls: some View {
        HStack(spacing: 24) {
            PauseButton(isPaused: model.phase == .paused) {
                Task { await model.togglePause() }
            }
            .disabled(!model.isActive)
            .accessibilityIdentifier("recordingPauseButton")
            RecordButton(isRecording: model.isActive, isBusy: model.isBusy || model.isProcessingTranscript) {
                if model.isActive { onStop() }
                else { Task { await model.toggleRecording() } }
            }
            .disabled(!model.isActive && !model.canStartRecording)
            .accessibilityIdentifier("recordingPrimaryButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 16, y: 7)
        .padding(.bottom, 6)
    }

    private var recordingStatusLabel: String {
        guard model.isProcessingTranscript else { return model.stateLabel }
        return LocalizationManager.shared.text(
            model.audioArchiveSaved ? "Audio saved" : "Finishing transcript…", table: "SpeakerProjection"
        )
    }

    private func adaptiveRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout { content() }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RecordView {
    init(model: RecorderModel) {
        self.init(model: model, onCollapse: {}, onStop: { Task { await model.toggleRecording() } })
    }
}

private struct MicrophoneDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Microphone access is off", systemImage: "mic.slash")
        } description: {
            Text("Transcript needs the microphone to record meetings. Everything stays on this device.")
        } actions: {
            Button("Open Settings") { MicrophonePermission.openSettings() }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.filledControl)
        }
    }
}

private struct InputSourcePicker: View {
    @State private var options: [AudioInputOption] = []
    @State private var selection: String?

    var body: some View {
        HStack {
            Label("Source", systemImage: "waveform.badge.mic")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Source", selection: $selection) {
                if options.isEmpty {
                    Text("Microphone").tag(String?.none)
                }
                ForEach(options) { option in
                    Text(option.name).tag(String?.some(option.id))
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal)
        .onAppear(perform: refresh)
        .onChange(of: selection) { _, new in
            guard let option = options.first(where: { $0.id == new }) else { return }
            AudioInputs.select(option)
        }
    }

    private func refresh() {
        options = AudioInputs.available()
        selection = AudioInputs.currentId() ?? options.first?.id
    }
}
