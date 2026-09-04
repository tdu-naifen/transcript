import Foundation
import Testing
@testable import TranscriptCore

let testiPhoneId = "device-iphone"
let testMacId = "device-mac"

func makeTestMeeting(id: String = UUID().uuidString, title: String = "Weekly sync", startedAt: Date = Date()) -> Meeting {
    Meeting(id: id, title: title, startedAt: startedAt, originDeviceId: testiPhoneId)
}

/// Keeps the embedding call sites focused on the vectors under test now that
/// `speakerEmbedding` carries the reserved HLC columns.
extension SpeakerEmbedding {
    init(speakerId: String, floats: [Float]) {
        self.init(speakerId: speakerId, floats: floats, originDeviceId: testiPhoneId)
    }
}

@Test func versionIsPresent() {
    #expect(TranscriptCore.version == "0.1.0")
}
