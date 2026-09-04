import SwiftUI

/// The large circular record/stop control.
struct RecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 4)
                    .frame(width: 88, height: 88)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 34, style: .continuous)
                    .fill(Color.red)
                    .frame(width: isRecording ? 34 : 68, height: isRecording ? 34 : 68)
            }
            .opacity(isBusy ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct PauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.title3)
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }
}

#Preview {
    HStack(spacing: 24) {
        PauseButton(isPaused: false) {}
        RecordButton(isRecording: true, isBusy: false) {}
    }
}
