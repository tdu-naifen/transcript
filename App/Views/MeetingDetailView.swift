import SwiftUI
import TranscriptCore

struct MeetingDetailView: View {
    let meeting: Meeting
    let audioURL: URL?
    let database: AppDatabase

    @State private var utterances: [Utterance] = []
    @State private var loadFailure: String?

    var body: some View {
        List {
            Section("Recording") {
                LabeledContent("Started", value: meeting.startedAt.formatted(date: .long, time: .shortened))
                LabeledContent("Duration", value: Format.duration(milliseconds: meeting.durationMs))
                LabeledContent("State", value: meeting.state.label)
                if let origin = meeting.failedFromState {
                    LabeledContent("Failed from", value: origin.label)
                }
            }

            Section("Audio") {
                LabeledContent("File", value: meeting.audioFileName ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                LabeledContent("Size", value: Format.bytes(meeting.audioByteCount))
                LabeledContent("SHA-256", value: Format.shortHash(meeting.audioSHA256))
                    .monospaced()
                if let audioURL {
                    LabeledContent("On disk", value: FileManager.default.fileExists(atPath: audioURL.path) ? "Yes" : "Missing")
                }
            }

            Section("Sync") {
                LabeledContent("Sent to Mac", value: meeting.syncedToMacAt?.formatted() ?? "Not yet")
                LabeledContent("Verified on Mac", value: meeting.audioVerifiedOnMacAt?.formatted() ?? "Not yet")
            }

            Section("Transcript") {
                if let loadFailure {
                    Text(loadFailure).font(.footnote).foregroundStyle(.orange)
                } else if utterances.isEmpty {
                    Text("No transcript for this recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(utterances) { utterance in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(Format.duration(milliseconds: utterance.startMs))
                                    .font(.caption2.monospacedDigit())
                                if let locale = utterance.localeIdentifier {
                                    Text(locale).font(.caption2)
                                }
                            }
                            .foregroundStyle(.tertiary)
                            Text(utterance.text).font(.callout)
                        }
                    }
                }
            }
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                utterances = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
            } catch {
                loadFailure = String(describing: error)
            }
        }
    }
}
