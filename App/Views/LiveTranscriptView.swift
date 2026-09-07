import SwiftUI
import TranscriptCore

/// Transcript lines as they arrive, newest at the top. The partial line at the top
/// keeps updating in place until the model commits it.
struct LiveTranscriptView: View {
    let model: TranscriptionModel
    var scrollsInternally = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerLayout {
                Image(systemName: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.lines.count) utterances", tableName: "RecordingLanguage")
                    .font(.subheadline.weight(.semibold))
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Text("Apple Speech")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)

            switch model.status {
            case .modelMissing:
                Text("Apple transcription is unavailable. Audio recording is still available.", tableName: "AppleSpeech")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing Apple transcription…", tableName: "AppleSpeech").font(.footnote).foregroundStyle(.secondary)
                }
            case .idle, .running:
                if model.lines.isEmpty {
                    Text(model.status == .running ? "Listening…" : "Transcript appears here while recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("liveTranscriptStatus")
                }
            }

            if let warning = model.speakerWarning {
                Text(warning).font(.caption).foregroundStyle(.secondary)
            }

            if scrollsInternally {
                ScrollView { transcriptLines }
                    .animation(.default, value: model.lines.count)
            } else {
                transcriptLines
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, scrollsInternally ? 108 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 7))
    }

    private var transcriptLines: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(model.lines) { line in
                TranscriptLineView(
                    line: line, speaker: model.speaker(for: line),
                    unresolvedSpeakerText: model.speakerIdentificationProgress.text,
                    projectionObservedAt: model.speakerProjectionObservedAt
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptLineView: View {
    let line: ASRSegment
    let speaker: Speaker?
    let unresolvedSpeakerText: String
    let projectionObservedAt: TimeInterval

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
                } else {
                    Text(unresolvedSpeakerText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(Format.duration(milliseconds: line.startMs))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(line.isFinal ? Color(red: 0.94, green: 0.29, blue: 0.25) : .secondary)
            }
            Text(line.text)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(line.isFinal ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("liveTranscriptLine")
        .onChange(of: projectionObservedAt, initial: true) {
            // SwiftUI update timing, not a claim of display scan-out or inference latency.
            if projectionObservedAt > 0 {
                LiveIdentityTiming.record(.rowUpdate, since: projectionObservedAt)
            }
        }
    }

    private var dotColor: Color {
        if let speaker { return Color.speaker(colorIndex: speaker.colorIndex) }
        return line.isFinal ? Color(red: 0.94, green: 0.29, blue: 0.25) : .secondary
    }

}
