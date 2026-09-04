import SwiftUI
import TranscriptCore

struct RecordView: View {
    @Bindable var model: RecorderModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                StatusChipRow(
                    stateLabel: model.stateLabel,
                    stateTint: model.phase == .recording ? .red : .secondary,
                    tier: .nemotron2240ms
                )

                if model.permission == .denied {
                    MicrophoneDeniedView()
                } else {
                    Text(Format.clock(model.elapsed))
                        .font(.system(size: 64, weight: .light, design: .monospaced))
                        .contentTransition(.numericText())
                        .monospacedDigit()

                    LevelMeterView(level: model.level, isActive: model.phase == .recording)
                        .padding(.horizontal)

                    InputSourcePicker()

                    if let notice = model.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .onTapGesture { model.dismissNotice() }
                    }

                    LiveTranscriptView(model: model.transcription)
                        .frame(maxHeight: .infinity)

                    HStack(spacing: 28) {
                        if model.isActive {
                            PauseButton(isPaused: model.phase == .paused) {
                                Task { await model.togglePause() }
                            }
                        }
                        RecordButton(isRecording: model.isActive, isBusy: model.isBusy) {
                            Task { await model.toggleRecording() }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding(.top, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
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
