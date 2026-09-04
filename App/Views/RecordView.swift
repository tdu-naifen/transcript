import SwiftUI
import TranscriptCore

struct RecordView: View {
    @Bindable var model: RecorderModel
    let onCollapse: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 1, green: 0.72, blue: 0.7), Color(red: 0.97, green: 0.97, blue: 0.965)],
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
                                .frame(width: 38, height: 38)
                                .background(Color.black.opacity(0.045), in: Circle())
                        }
                        .accessibilityLabel("Collapse recording")
                        .accessibilityIdentifier("collapseRecordingButton")
                        Spacer()
                    }

                    Text(Format.clock(model.elapsed))
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .monospacedDigit()
                        .padding(.bottom, 8)

                    LevelMeterView(level: model.level, isActive: model.phase == .recording)
                        .frame(height: 26)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)

                Group {
                    if model.permission == .denied {
                        MicrophoneDeniedView()
                    } else {
                        ZStack(alignment: .bottom) {
                            LiveTranscriptView(model: model.transcription)
                                .frame(maxHeight: .infinity)

                            LinearGradient(
                                colors: [.white.opacity(0), .white],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 116)
                            .allowsHitTesting(false)

                            HStack(spacing: 24) {
                                PauseButton(isPaused: model.phase == .paused) {
                                    Task { await model.togglePause() }
                                }
                                RecordButton(isRecording: model.isActive, isBusy: model.isBusy) {
                                    Task {
                                        await model.toggleRecording()
                                        if !model.isActive { onCollapse() }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.1), radius: 16, y: 7)
                            .padding(.bottom, 16)
                        }
                        .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
        .accessibilityIdentifier("expandedRecordingView")
    }
}

extension RecordView {
    init(model: RecorderModel) {
        self.init(model: model, onCollapse: {})
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
