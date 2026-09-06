import Foundation
import TranscriptCore

struct MacLibraryItem: Identifiable, Sendable {
    let meeting: Meeting
    let utterances: [Utterance]
    let speakers: [Speaker]

    var id: String { meeting.id }
}
