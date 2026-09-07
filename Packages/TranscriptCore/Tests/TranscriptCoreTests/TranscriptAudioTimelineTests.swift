import CoreMedia
import XCTest
@testable import TranscriptCore

final class TranscriptAudioTimelineTests: XCTestCase {
    func testProducerAddsFrameOriginBeforeRoundingOnce() throws {
        let origin = CMTime(value: 8, timescale: 16_000)
        let range = CMTimeRange(start: CMTime(value: 8, timescale: 16_000),
                                duration: CMTime(value: 16, timescale: 16_000))
        let result = try TranscriptAudioTimeline.bounds(for: range, origin: origin, finalInputEndMs: 2)
        XCTAssertEqual(result.startMs, 1)
        XCTAssertEqual(result.endMs, 2)
        let oldEnd = Int((origin.seconds * 1000).rounded())
            + Int((CMTimeRangeGetEnd(range).seconds * 1000).rounded())
        XCTAssertEqual(oldEnd, 3, "Regression: old independent rounding exceeds the 2 ms capture boundary")
    }

    func testProducerRejectsUnboundedFinalWithoutClampingOrChangingInput() throws {
        for end in [9147, 9148, 9149] {
            let range = CMTimeRange(start: .zero, duration: CMTime(value: Int64(end), timescale: 1000))
            let original = range
            if end <= 9148 {
                let result = try TranscriptAudioTimeline.bounds(for: range, finalInputEndMs: 9148)
                XCTAssertEqual(result.endMs, end)
            } else {
                XCTAssertThrowsError(try TranscriptAudioTimeline.bounds(for: range, finalInputEndMs: 9148)) {
                    guard case TranscriptAudioTimeline.Failure.invalidTiming = $0 else {
                        return XCTFail("Expected explicit invalid timing, not truncation")
                    }
                }
            }
            XCTAssertEqual(range, original)
        }
    }

    func testProducerRejectsNonnumericNegativeAndOverflowingTimes() throws {
        for range in [
            CMTimeRange.invalid,
            CMTimeRange(start: .indefinite, duration: .zero),
            CMTimeRange(start: CMTime(value: -1, timescale: 1000), duration: .zero),
            CMTimeRange(start: .zero, duration: CMTime(value: -1, timescale: 1000))
        ] {
            XCTAssertThrowsError(try TranscriptAudioTimeline.bounds(for: range))
        }
        for seconds in [Double.nan, .infinity, -.infinity, -1, Double(Int.max)] {
            XCTAssertThrowsError(try TranscriptAudioTimeline.milliseconds(seconds))
        }
    }
}
