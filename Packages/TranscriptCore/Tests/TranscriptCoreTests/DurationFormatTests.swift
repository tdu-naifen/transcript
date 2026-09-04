import Testing
@testable import TranscriptCore

@Test func durationLabelZeroSeconds() {
    #expect(DurationFormat.label(milliseconds: 0) == "0秒")
}

@Test func durationLabelSeconds() {
    #expect(DurationFormat.label(milliseconds: 5_000) == "5秒")
}

@Test func durationLabelSubMinuteUpperBoundary() {
    #expect(DurationFormat.label(milliseconds: 59_000) == "59秒")
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
