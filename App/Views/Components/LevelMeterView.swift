import SwiftUI
import TranscriptCore

/// Bar meter fed by the dedicated level stream, never by the ASR chunk stream.
struct LevelMeterView: View {
    let level: AudioLevel
    let isActive: Bool

    private let barCount = 28

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(height: height(for: index))
            }
        }
        .frame(height: 44)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private var filled: Int {
        guard isActive else { return 0 }
        return Int((Double(level.normalized) * Double(barCount)).rounded())
    }

    private func color(for index: Int) -> Color {
        guard index < filled else { return Color.secondary.opacity(0.18) }
        return index > barCount - 4 ? .orange : .accentColor
    }

    private func height(for index: Int) -> CGFloat {
        let base: CGFloat = 8
        guard index < filled else { return base }
        let ramp = CGFloat(index) / CGFloat(barCount)
        return base + 36 * (0.35 + 0.65 * ramp)
    }
}

#Preview {
    LevelMeterView(level: AudioLevel(rms: 0.2, peak: 0.4), isActive: true)
        .padding()
}
