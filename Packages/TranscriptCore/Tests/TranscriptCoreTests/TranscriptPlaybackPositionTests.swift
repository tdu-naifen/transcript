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

    @Test func singleLineIncludesItsStartAndRemainsSelectedAfterItsEnd() {
        let utterances = [line(-100)]
        for (position, expected) in [(-101, nil), (-100, 0), (0, 0), (Int.max, 0)] as [(Int, Int?)] {
            #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: position) == expected)
        }
    }

    @Test func duplicateStartsSelectTheLastMatchingLine() {
        let utterances = [-500, -500, 0, 0, 0, 5_000, 5_000].map(line)
        let cases: [(Int, Int?)] = [
            (-501, nil), (-500, 1), (-1, 1), (0, 4),
            (4_999, 4), (5_000, 6), (Int.max, 6)
        ]
        for (position, expected) in cases {
            #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: position) == expected)
        }
        #expect(TranscriptPlaybackPosition.currentIndex(utterances: [line(0), line(0), line(0)], atMs: 0) == 2)
    }

    @Test func gapAfterLineEndKeepsThePreviousLineSelected() {
        let utterances = [line(0), line(5_000)]
        #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: 3_000) == 0)
    }

    @Test func timestampExtremesDoNotOverflow() {
        var last = line(0)
        last.startMs = Int.max
        last.endMs = Int.max
        let utterances = [line(Int.min), line(-1), last]
        for (position, expected) in [(Int.min, 0), (Int.min + 1, 0), (-1, 1), (Int.max - 1, 1), (Int.max, 2)] {
            #expect(TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: position) == expected)
        }
    }

    @Test func largeSortedTranscriptMatchesReferenceLinearLookup() {
        let utterances = (0..<10_000).map { line(($0 / 3) * 25 - 40_000) }
        let positions = [Int.min, -40_001, -40_000, -39_999, 0, 43_325, 43_326, Int.max]
            + deterministicPositions(count: 256, upperBound: 100_000).map { $0 - 50_000 }
        for position in positions {
            #expect(
                TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: position)
                    == referenceLinearIndex(utterances: utterances, atMs: position),
                "Position: \(position)"
            )
        }
    }

    private func referenceLinearIndex(utterances: [Utterance], atMs positionMs: Int) -> Int? {
        var result: Int?
        for (index, utterance) in utterances.enumerated() {
            guard utterance.startMs <= positionMs else { break }
            result = index
        }
        return result
    }

    private func deterministicPositions(count: Int, upperBound: Int) -> [Int] {
        var seed: UInt64 = 0x51A7
        return (0..<count).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(upperBound))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPT_PLAYBACK_BENCHMARK"] == "1"))
    func benchmarkLookupBatch() {
        let utterances = (0..<10_000).map { line(($0 / 3) * 25 - 40_000) }
        let positions = (0..<50).map { 40_000 + $0 * 70 }
            + deterministicPositions(count: 50, upperBound: 100_000).map { $0 - 50_000 }
        let expected = positions.reduce(0) { $0 + (referenceLinearIndex(utterances: utterances, atMs: $1) ?? -1) }
        let clock = ContinuousClock()
        var milliseconds: [Double] = []
        for iteration in 0..<35 {
            var checksum = 0
            let duration = clock.measure {
                for position in positions {
                    checksum += TranscriptPlaybackPosition.currentIndex(utterances: utterances, atMs: position) ?? -1
                }
            }
            #expect(checksum == expected)
            if iteration >= 5 {
                let parts = duration.components
                milliseconds.append(Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
            }
        }
        let sorted = milliseconds.sorted()
        let median = (sorted[14] + sorted[15]) / 2
        let p95 = sorted[28]
        print("PLAYBACK_LOOKUP_BENCHMARK unit=ms/batch utterances=10000 queries=100 late=50 seeded=50 warmup=5 repeats=30 checksum=\(expected)")
        print("PLAYBACK_LOOKUP_BENCHMARK raw=\(milliseconds) median=\(median) p95_nearest_rank=\(p95)")
    }
}
