import SwiftUI

/// Playback controls inside the detail screen's bottom safe-area inset.
struct AudioPlayerBar: View {
    let playback: AudioPlaybackModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let accent = Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255)

    var body: some View {
        VStack(spacing: 8) {
            if case .unavailable(let reason) = playback.availability {
                Label(reason.text, systemImage: "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("audioUnavailableReason")
            } else {
                AudioWaveformScrubber(playback: playback, accent: accent)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 24 : 40)

                HStack {
                    Text(Format.clock(Double(playback.currentTimeMs) / 1_000))
                    Spacer()
                    Text(Format.clock(Double(playback.durationMs) / 1_000))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button { playback.skip(-5) } label: {
                        Image(systemName: "gobackward.5")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Skip back 5 seconds")
                    Spacer(minLength: 0)
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 48, minHeight: 48)
                            .background(accent, in: Circle())
                    }
                    .accessibilityLabel(playback.isPlaying ? Text("Pause audio") : Text("Play audio"))
                    .accessibilityIdentifier("audioPlayPauseButton")
                    Spacer(minLength: 0)
                    Button { playback.skip(5) } label: {
                        Image(systemName: "goforward.5")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Skip forward 5 seconds")
                    Spacer(minLength: 0)
                    Button { playback.cycleSpeed() } label: {
                        Text(playback.speed.label)
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(playback.speed.label)
                    .accessibilityIdentifier("audioSpeedButton")
                }
                .font(.title3)
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}

private struct AudioWaveformScrubber: View {
    let playback: AudioPlaybackModel
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let progressX = proxy.size.width * playback.progress
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(playback.waveform.enumerated()), id: \.offset) { index, amplitude in
                        Capsule()
                            .fill(Double(index) / Double(max(1, playback.waveform.count - 1)) <= playback.progress
                                ? accent : Color.secondary.opacity(0.28))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(4, CGFloat(amplitude) * proxy.size.height))
                    }
                }
                if !playback.waveform.isEmpty {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 2, height: proxy.size.height)
                        .offset(x: progressX)
                } else {
                    // Seeking remains available even if waveform extraction fails.
                    Capsule().fill(Color.secondary.opacity(0.28)).frame(height: 4)
                    Circle().fill(accent).frame(width: 8, height: 8).offset(x: progressX - 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let progress = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                        playback.seek(toMs: Int(progress * Double(playback.durationMs)))
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio waveform")
        .accessibilityValue(Text(playback.progress, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.skip(5)
            case .decrement: playback.skip(-5)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("audioWaveformScrubber")
    }
}
