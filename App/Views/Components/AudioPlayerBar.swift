import SwiftUI

/// Player pinned at the bottom of `MeetingDetailView` (UI.md §3a). Degrades to a
/// disabled scaffold with an explanation instead of a broken player when
/// `playback.availability` is `.unavailable`.
struct AudioPlayerBar: View {
    let playback: AudioPlaybackModel

    private var isReady: Bool { playback.availability == .ready }

    var body: some View {
        VStack(spacing: 10) {
            if case .unavailable(let reason) = playback.availability {
                Label(reason.text, systemImage: "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isReady {
                AudioWaveformScrubber(playback: playback)
                    .frame(height: 54)
            }

            HStack {
                Text(Format.clock(Double(playback.currentTimeMs) / 1_000))
                Spacer()
                Text(Format.clock(Double(playback.durationMs) / 1_000))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Button { playback.skip(-5) } label: {
                    Image(systemName: "gobackward.5")
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.72), in: Circle())
                }
                Spacer()
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color(red: 0.94, green: 0.29, blue: 0.25), in: Circle())
                }
                .accessibilityIdentifier("audioPlayPauseButton")
                Spacer()
                Button { playback.skip(5) } label: {
                    Image(systemName: "goforward.5")
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.72), in: Circle())
                }
                Spacer()
                Button { playback.cycleSpeed() } label: {
                    Text(playback.speed.label)
                        .font(.footnote.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.72), in: Circle())
                }
                .accessibilityIdentifier("audioSpeedButton")
            }
            .font(.title3)
            .disabled(!isReady)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

private struct AudioWaveformScrubber: View {
    let playback: AudioPlaybackModel

    var body: some View {
        GeometryReader { proxy in
            let progressX = proxy.size.width * playback.progress
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(playback.waveform.enumerated()), id: \.offset) { index, amplitude in
                        Capsule()
                            .fill(Double(index) / Double(max(1, playback.waveform.count - 1)) <= playback.progress
                                ? Color.red : Color.secondary.opacity(0.28))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(4, CGFloat(amplitude) * proxy.size.height))
                    }
                }

                if !playback.waveform.isEmpty {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 1, height: proxy.size.height)
                        .offset(x: progressX)
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .offset(x: progressX - 3.5)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let progress = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                        playback.seek(toMs: Int(progress * Double(playback.durationMs)))
                    }
            )
        }
        .accessibilityLabel("Audio waveform")
        .accessibilityValue("\(Int(playback.progress * 100)) percent")
        .accessibilityIdentifier("audioWaveformScrubber")
    }
}
