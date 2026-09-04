import SwiftUI
import TranscriptCore

/// Transcript lines as they arrive, newest at the top. The partial line at the top
/// keeps updating in place until the model commits it.
struct LiveTranscriptView: View {
    let model: TranscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.lines.count) utterances")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Nemotron")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)

            switch model.status {
            case .modelMissing:
                Text("Model not downloaded — recording still works. Download it in Settings to transcribe.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading model…").font(.footnote).foregroundStyle(.secondary)
                }
            case .idle, .running:
                if model.lines.isEmpty {
                    Text(model.status == .running ? "Listening…" : "Transcript appears here while recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.lines) { line in
                        TranscriptLineView(line: line, speaker: model.speaker(for: line))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.default, value: model.lines.count)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 108)
    }
}

private struct TranscriptLineView: View {
    let line: ASRSegment
    let speaker: Speaker?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                if let speaker {
                    Text(speaker.resolvedName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.speaker(colorIndex: speaker.colorIndex))
                }
                Text(Format.duration(milliseconds: line.startMs))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(line.isFinal ? Color(red: 0.94, green: 0.29, blue: 0.25) : .secondary)
            }
            Text(line.text)
                .font(.system(size: 17, weight: .regular))
                .lineSpacing(3)
                .foregroundStyle(line.isFinal ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("liveTranscriptLine")
    }

    private var dotColor: Color {
        if let speaker { return Color.speaker(colorIndex: speaker.colorIndex) }
        return line.isFinal ? Color(red: 0.94, green: 0.29, blue: 0.25) : .secondary
    }
}
