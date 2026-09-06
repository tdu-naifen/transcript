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
        let gate = RequestGate()
        let model = HomeModel(searchHandler: { query in
            await gate.wait(query.text)
            return try await repository.search(query)
        })

        model.query = "slow"
        model.filtersChanged()
        model.query = "fast"
        model.filtersChanged()
        await gate.release("fast")
        try await waitUntil { model.results.map(\.meeting.id) == ["fast"] }
        await gate.release("slow")
        await Task.yield()

        XCTAssertEqual(model.results.map(\.meeting.id), ["fast"])
        XCTAssertNil(model.errorMessage)
    }

    func testInvalidDateAndClearCancelGenerationAndStopLoading() async throws {
        let database = try AppDatabase.inMemory()
        try await MeetingRepository(database).insert(makeMeeting(id: "slow", title: "slow"))
        let repository = SearchRepository(database)
        let gate = RequestGate()
        let model = HomeModel(searchHandler: { query in
            await gate.wait(query.text)
            return try await repository.search(query)
        })
        model.query = "slow"
        model.filtersChanged()
        model.usesDateRange = true
        model.startDate = Date(timeIntervalSince1970: 200_000)
        model.endDate = Date(timeIntervalSince1970: 100_000)
        model.filtersChanged()
        XCTAssertFalse(model.isLoading)
        model.clearFilters()
        XCTAssertFalse(model.isLoading)
        await gate.release("slow")
        await Task.yield()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isLoading)
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

    private actor RequestGate {
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<String> = []

        func wait(_ key: String) async {
            if released.remove(key) != nil { return }
            await withCheckedContinuation { continuation in
                waiters[key] = continuation
            }
        }

        func release(_ key: String) {
            if let waiter = waiters.removeValue(forKey: key) {
                waiter.resume()
            } else {
                released.insert(key)
            }
        }
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
