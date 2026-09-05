import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class HomeSearchTests: XCTestCase {
    func testProductionModelCancelsSlowGeneration() async throws {
        let database = try AppDatabase.inMemory()
        try await MeetingRepository(database).insert(makeMeeting(id: "slow", title: "slow"))
        try await MeetingRepository(database).insert(makeMeeting(id: "fast", title: "fast"))
        let repository = SearchRepository(database)
        let model = HomeModel(searchHandler: { query in
            if query.text == "slow" {
                try await Task.sleep(for: .milliseconds(150))
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
            return try await repository.search(query)
        })

        model.query = "slow"
        model.filtersChanged()
        model.query = "fast"
        model.filtersChanged()
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(model.results.map(\.meeting.id), ["fast"])
        XCTAssertNil(model.errorMessage)
    }

    func testRealSearchRepositoryReturnsTitleAndTranscriptHit() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = makeMeeting(id: "real-search", title: "Planning review")
        try await MeetingRepository(database).insert(meeting)
        try await UtteranceRepository(database).append(Utterance(
            id: "real-hit", meetingId: meeting.id, startMs: 1_250, endMs: 2_000,
            text: "body needle", originDeviceId: "test-device"
        ))
        let repository = SearchRepository(database)
        let model = HomeModel(searchHandler: { query in
            try await repository.search(query)
        })

        model.query = "needle"
        model.filtersChanged()
        try await waitUntil { model.hasLoaded }

        XCTAssertEqual(model.results.map(\.meeting.id), [meeting.id])
        XCTAssertEqual(model.results.first?.hits.map(\.utteranceId), ["real-hit"])
        XCTAssertFalse(model.results.first?.titleMatched ?? true)
    }

    func testInclusiveDateRangeUsesCalendarDayAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let model = HomeModel()
        model.startDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8))!
        model.endDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 9))!

        let range = try XCTUnwrap(model.inclusiveDateRange(calendar: calendar))
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 47 * 60 * 60)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("condition timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeMeeting(id: String, title: String) -> Meeting {
        Meeting(id: id, title: title, startedAt: Date(timeIntervalSince1970: 1_700_000_000), originDeviceId: "test-device")
    }
}
