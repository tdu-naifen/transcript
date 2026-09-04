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
                    .fill(Color(red: 0.94, green: 0.18, blue: 0.2))
                    .frame(width: 58, height: 58)
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
