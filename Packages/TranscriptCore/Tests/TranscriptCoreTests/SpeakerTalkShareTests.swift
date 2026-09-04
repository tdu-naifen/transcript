import Foundation
import Testing
@testable import TranscriptCore

@Suite struct SpeakerTalkShareTests {
    private func line(_ speakerId: String?, _ startMs: Int, _ endMs: Int) -> Utterance {
        Utterance(
            meetingId: "meeting", startMs: startMs, endMs: endMs, text: "x",
            speakerId: speakerId, originDeviceId: testiPhoneId
        )
    }

    @Test func singleSpeakerIsAllOfIt() {
        let utterances = [line("a", 0, 1_000), line("a", 1_000, 2_000)]
        #expect(SpeakerTalkShare.percentages(utterances: utterances, speakerIds: ["a"]) == ["a": 100])
    }

    @Test func splitsProportionallyBetweenSpeakers() {
        let utterances = [line("a", 0, 3_000), line("b", 3_000, 4_000)]
        let result = SpeakerTalkShare.percentages(utterances: utterances, speakerIds: ["a", "b"])
        #expect(result["a"] == 75)
        #expect(result["b"] == 25)
    }

    @Test func noUtterancesIsZeroForEveryone() {
        #expect(SpeakerTalkShare.percentages(utterances: [], speakerIds: ["a", "b"]) == ["a": 0, "b": 0])
    }

    @Test func unassignedLinesCountTowardTotalButNoOne() {
        // "a" spoke for 1s out of a 4s total (3s unassigned) -> 25%, not 100%.
        let utterances = [line("a", 0, 1_000), line(nil, 1_000, 4_000)]
        #expect(SpeakerTalkShare.percentages(utterances: utterances, speakerIds: ["a"]) == ["a": 25])
    }

    @Test func speakerWithNoLinesIsZero() {
        let utterances = [line("a", 0, 1_000)]
        #expect(SpeakerTalkShare.percentages(utterances: utterances, speakerIds: ["a", "b"]) == ["a": 100, "b": 0])
    }
}
