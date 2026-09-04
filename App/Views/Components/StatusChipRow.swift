import SwiftUI
import TranscriptCore

struct StatusChip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Format / sample-rate / state strip along the top of the record screen.
struct StatusChipRow: View {
    let stateLabel: String
    let stateTint: Color
    let tier: AudioChunkTier

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(text: "M4A", symbol: "waveform")
            StatusChip(text: "16 kHz", symbol: "dial.high")
            StatusChip(text: "\(tier.milliseconds) ms", symbol: "timer")
            StatusChip(text: stateLabel, symbol: "circle.fill", tint: stateTint)
        }
    }
}

#Preview {
    StatusChipRow(stateLabel: "Recording", stateTint: .red, tier: .nemotron2240ms)
}
