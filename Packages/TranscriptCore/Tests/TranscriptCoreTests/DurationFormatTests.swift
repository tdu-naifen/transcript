import Testing
@testable import TranscriptCore

import Foundation
import Testing
@testable import TranscriptCore

private let zhHans = Locale(identifier: "zh-Hans")
private let en = Locale(identifier: "en")

@Test func durationLabelZeroSeconds() {
    #expect(DurationFormat.label(milliseconds: 0, locale: zhHans) == "0秒")
}

@Test func durationLabelSeconds() {
    #expect(DurationFormat.label(milliseconds: 5_000, locale: zhHans) == "5秒")
}

@Test func durationLabelSubMinuteUpperBoundary() {
    #expect(DurationFormat.label(milliseconds: 59_000, locale: zhHans) == "59秒")
}

@Test func durationLabelSecondsEnglish() {
    #expect(DurationFormat.label(milliseconds: 5_000, locale: en) == "5s")
}

@Test func durationLabelExactlyOneMinute() {
    #expect(DurationFormat.label(milliseconds: 60_000) == "01:00")
}

@Test func durationLabelMinutes() {
    #expect(DurationFormat.label(milliseconds: 8 * 60_000) == "08:00")
    #expect(DurationFormat.label(milliseconds: 45 * 60_000 + 30_000) == "45:30")
}

@Test func durationLabelExactlyOneHour() {
    #expect(DurationFormat.label(milliseconds: 3_600_000) == "1:00:00")
}

@Test func durationLabelOverAnHour() {
    #expect(DurationFormat.label(milliseconds: 90 * 60_000) == "1:30:00")
}

@Test func durationLabelMinutesUnaffectedByLocale() {
    // >= 60s falls back to digit-only `clock`, which is locale-invariant.
    #expect(DurationFormat.label(milliseconds: 60_000, locale: en) == "01:00")
}

