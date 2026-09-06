import Foundation
import TranscriptCore

enum MacSampleLibrary {
    // These read-only examples never enter the on-disk library or network.
    static let items: [MacLibraryItem] = {
        let origin = "mac-design-sample"
        let speakers = [
            Speaker(id: "sample-lin", displayName: String(localized: "Lin"), anonymousName: "Hippo", colorIndex: 0, originDeviceId: origin),
            Speaker(id: "sample-otter", anonymousName: "Otter", colorIndex: 1, originDeviceId: origin),
            Speaker(id: "sample-zhou", displayName: String(localized: "Zhou"), anonymousName: "Wren", colorIndex: 5, originDeviceId: origin)
        ]
        let titles = [
            String(localized: "Product design weekly"),
            String(localized: "User interviews"),
            String(localized: "Brand direction"),
            String(localized: "Quarterly review")
        ]
        let texts = [
            String(localized: "Let's connect the phone and desktop experience. Capture a meeting on iPhone, then continue organizing it on Mac."),
            String(localized: "The colors should feel like one product. Keep our deep blue and let the meeting content take center stage."),
            String(localized: "Pairing should be simple: choose the Mac, compare the code, and return to your meetings once both devices confirm."),
            String(localized: "Let's make connection and delivery reliable first. Processing progress and sync status should each tell a clear story.")
        ]
        return titles.enumerated().map { index, title in
            let meeting = Meeting(
                id: "sample-\(index)", title: title,
                startedAt: Date(timeIntervalSince1970: 1_788_703_200 - Double(index * 86_400)),
                durationMs: [2_532_000, 2_160_000, 1_680_000, 3_300_000][index],
                state: .recorded, originDeviceId: origin
            )
            let utterances = texts.enumerated().map { offset, text in
                Utterance(
                    id: "sample-\(index)-\(offset)", meetingId: meeting.id,
                    startMs: [42_000, 78_000, 124_000, 168_000][offset],
                    endMs: [74_000, 118_000, 161_000, 195_000][offset],
                    text: text, speakerId: speakers[offset % speakers.count].id,
                    engine: .appleSpeech, originDeviceId: origin
                )
            }
            return MacLibraryItem(meeting: meeting, utterances: utterances, speakers: speakers)
        }
    }()
}
