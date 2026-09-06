import SwiftUI
import TranscriptCore

struct RecordView: View {
    @Bindable var model: RecorderModel
    let onCollapse: () -> Void
    let onStop: () -> Void
    var onStart: (() -> Void)? = nil
    var isStartingRecording = false
    @State private var isStarting = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [FloatingRecordButton.accent.opacity(0.12), Color(uiColor: .systemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    HStack {
                        Button(action: onCollapse) {
                            Image(systemName: "chevron.down")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .background(Color.secondary.opacity(0.1), in: Circle())
                        }
                        .accessibilityLabel("Collapse recording")
                        .accessibilityIdentifier("collapseRecordingButton")
                        Spacer()
                        Label {
                            Text("On-device", tableName: "AppleSpeech")
                        } icon: {
                            Image(systemName: "iphone")
                        }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Text("M4A")
                        Text("\((model.recordingSampleRate / 1_000).formatted()) kHz")
                        Label(model.stateLabel, systemImage: model.isActive ? "record.circle" : "mic")
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

                    LevelMeterView(level: model.level, isActive: model.phase == .recording)
                        .frame(height: 26)
                    HStack(spacing: 8) {
                        Label("Apple Speech", systemImage: "waveform")
                        Spacer(minLength: 4)
                        Label(model.recordingLanguageLabel, systemImage: "globe")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)

                Group {
                    if model.permission == .denied {
                        MicrophoneDeniedView()
                    } else {
                        ZStack(alignment: .bottom) {
                            LiveTranscriptView(model: model.transcription)
                                .frame(maxHeight: .infinity)

                            HStack(spacing: 24) {
                                PauseButton(isPaused: model.phase == .paused) {
                                    Task { await model.togglePause() }
                                }
                                RecordButton(isRecording: model.isActive, isBusy: model.isBusy) {
                                    if model.isActive {
                                        onStop()
                                    } else {
                                        Task { await model.toggleRecording() }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 1))
                            .shadow(color: .black.opacity(0.1), radius: 16, y: 7)
                            .padding(.bottom, 16)
                        }
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
                .frame(maxHeight: .infinity)
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
