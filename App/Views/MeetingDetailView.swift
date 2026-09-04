import SwiftUI
import TranscriptCore

struct MeetingDetailView: View {
    let meeting: Meeting
    let audioURL: URL?

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
                Text("Transcription arrives in the next milestone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
