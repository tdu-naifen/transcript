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
                Label(reason, systemImage: "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Slider(
                value: Binding(
                    get: { playback.progress },
                    set: { playback.seek(toMs: Int($0 * Double(playback.durationMs))) }
                ),
                in: 0...1
            )
            .disabled(!isReady)

            HStack {
                Text(Format.clock(Double(playback.currentTimeMs) / 1_000))
                Spacer()
                Text(Format.clock(Double(playback.durationMs) / 1_000))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 32) {
                Button { playback.skip(-15) } label: {
                    Image(systemName: "gobackward.15")
                }
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                }
                Button { playback.skip(15) } label: {
                    Image(systemName: "goforward.15")
                }
                Button { playback.cycleSpeed() } label: {
                    Text(playback.speed.label)
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 32)
                }
            }
            .font(.title2)
            .disabled(!isReady)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
