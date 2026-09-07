import Foundation
import Testing
@testable import TranscriptCore

struct LiveSpeakerTimingTests {
    @Test func timingUsesMonotonicMillisecondsAndClampsNegativeIntervals() {
        let start = ContinuousClock.now
        #expect(LiveSpeakerTiming.milliseconds(from: start, to: start.advanced(by: .milliseconds(1_250))) == 1_250)
        #expect(LiveSpeakerTiming.milliseconds(from: start, to: start.advanced(by: .microseconds(250))) == 0.25)
        #expect(LiveSpeakerTiming.milliseconds(from: start, to: start.advanced(by: .seconds(-1))) == 0)
    }
}
