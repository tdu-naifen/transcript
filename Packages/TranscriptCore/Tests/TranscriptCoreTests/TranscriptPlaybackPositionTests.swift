import Foundation
import Testing
@testable import TranscriptCore

@Suite struct TranscriptPlaybackPositionTests {
    private func line(_ startMs: Int) -> Utterance {
        Utterance(meetingId: "meeting", startMs: startMs, endMs: startMs + 1_000, text: "x", originDeviceId: testiPhoneId)
    }

    @Test func beforeFirstLineIsNil() {
        let utterances = [line(1_000), line(2_000)]
        #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: 500) == nil)
    }

    @Test func exactlyOnALineStartSelectsThatLine() {
        let utterances = [line(1_000), line(2_000)]
        #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: 2_000) == 1)
    }

    @Test func betweenTwoLinesSelectsTheEarlierOne() {
        let utterances = [line(1_000), line(2_000)]
        #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: 1_500) == 0)
    }

    @Test func afterLastLineSelectsTheLastLine() {
        let utterances = [line(1_000), line(2_000)]
        #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: 999_999) == 1)
    }

    @Test func emptyTranscriptIsNil() {
        #expect(TranscriptPlaybackPosition.currentIndex(utterances: [], atMs: 0) == nil)
    }
}
