import SwiftUI
import TranscriptCore

/// Transcript lines as they arrive, newest at the top. The partial line at the top
/// keeps updating in place until the model commits it.
struct LiveTranscriptView: View {
    let model: TranscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

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
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.lines) { line in
                        TranscriptLineView(line: line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.default, value: model.lines.count)
        }
        .padding(.horizontal)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusChip(text: "Nemotron", symbol: "cpu", tint: model.isAvailable ? .accentColor : .secondary)
            if let unit = model.computeUnit {
                StatusChip(text: unit, symbol: "bolt", tint: .teal)
            }
            if let language = model.detectedLanguage {
                StatusChip(text: language, symbol: "globe", tint: .purple)
            }
            Spacer()
        }
    }
}

private struct TranscriptLineView: View {
    let line: ASRSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.duration(milliseconds: line.startMs))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(line.text)
                .font(.callout)
                .foregroundStyle(line.isFinal ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
