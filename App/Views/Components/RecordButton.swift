import SwiftUI

/// The large circular record/stop control.
struct RecordButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.94, green: 0.18, blue: 0.2))
                    .frame(width: 48, height: 48)
                if isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white)
                        .frame(width: 18, height: 18)
                }
            }
            .opacity(isBusy ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isRecording)
        .accessibilityLabel(LocalizedStringKey(isRecording ? "Stop recording" : "Start recording"))
        .accessibilityIdentifier(isRecording ? "expandedStopButton" : "expandedStartButton")
    }
}

struct PauseButton: View {
    let isPaused: Bool
    var diameter: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.title3)
                .frame(width: diameter, height: diameter)
                .background(Color.secondary.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(isPaused ? "Resume recording" : "Pause recording"))
    }
}

#Preview {
    HStack(spacing: 24) {
        PauseButton(isPaused: false) {}
        RecordButton(isRecording: true, isBusy: false) {}
    }
}
