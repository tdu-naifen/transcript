import Foundation
import Testing
@testable import TranscriptCore

@Suite struct MeetingTitleTests {
    @Test func defaultTitleIncludesRecordingDateAndTime() {
        let title = MeetingTitle.defaultTitle(
            startedAt: Date(timeIntervalSince1970: 1_788_552_600),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(title.contains("Sep 4, 2026"))
        #expect(title.contains("8:10"))
        #expect(title.contains("PM"))
    }

    @Test func confirmedTitleTrimsUserName() {
        #expect(MeetingTitle.confirmedTitle("  Customer interview\n", defaultTitle: "Sep 4") == "Customer interview")
    }

    @Test func emptyConfirmedTitleUsesSafeDefault() {
        #expect(MeetingTitle.confirmedTitle(" \n ", defaultTitle: "Sep 4") == "Sep 4")
    }
}