import XCTest
@testable import Transcript
@testable import TranscriptCore

@MainActor
final class HomeSearchTests: XCTestCase {
    func testFailedPageRetriesSameCursorWithoutSkippingOrDuplicatingMeetings() async throws {
        let gate = PageGate()
        let model = HomeModel(searchHandler: { try await gate.search($0) })
        let cursor = makeCursor("page-2")
        let finalCursor = makeCursor("page-3")
        model.query = "needle"
        model.filtersChanged()
        await gate.resolve(0, with: .success(page(["first"], next: cursor)))
        try await waitUntil { !model.isLoading }
        model.loadMore()
        await gate.resolve(1, with: .failure(PageError.failed))
        try await waitUntil { !model.isLoading }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.nextCursor, cursor)
        XCTAssertEqual(model.results.map(\.meeting.id), ["first"])

        model.loadMore()
        XCTAssertTrue(model.isLoading, "Failure must leave the same page retryable")
        guard model.isLoading else { return }
        await gate.resolve(2, with: .success(page(["first", "second", "second"], next: finalCursor)))
        try await waitUntil { !model.isLoading }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.results.map(\.meeting.id), ["first", "second"])
        XCTAssertEqual(model.nextCursor, finalCursor)
        model.loadMore()
        await gate.resolve(3, with: .success(page(["second", "third"], next: nil)))
        try await waitUntil { !model.isLoading }
        XCTAssertEqual(model.results.map(\.meeting.id), ["first", "second", "third"])
        XCTAssertNil(model.nextCursor)
        let requests = await gate.requests
        XCTAssertEqual(requests.map(\.cursor), [nil, cursor, cursor, finalCursor])
    }

    func testOldLoadMoreSuccessAndFailureCannotChangeNewFilterGeneration() async throws {
        for oldFails in [false, true] {
            let gate = PageGate()
            let model = HomeModel(searchHandler: { try await gate.search($0) })
            let oldCursor = makeCursor("old")
            let newCursor = makeCursor("new")
            model.query = "old"
            model.filtersChanged()
            await gate.resolve(0, with: .success(page(["old-first"], next: oldCursor)))
            try await waitUntil { !model.isLoading }
            let oldPage = model.loadMore()
            await gate.waitForRequest(1)
            model.speakerIDs = ["new-speaker"]
            model.query = "new"
            model.filtersChanged()
            await gate.waitForRequest(2)
            await gate.resolve(1, with: oldFails
                ? .failure(PageError.failed)
                : .success(page(["stale"], next: oldCursor)))
            await oldPage?.value
            XCTAssertTrue(model.isLoading)
            XCTAssertTrue(model.results.isEmpty)
            XCTAssertNil(model.nextCursor)
            XCTAssertNil(model.errorMessage)
            await gate.resolve(2, with: .success(page(["new-first"], next: newCursor)))
            try await waitUntil { !model.isLoading }
            XCTAssertEqual(model.results.map(\.meeting.id), ["new-first"])
            XCTAssertEqual(model.nextCursor, newCursor)
            XCTAssertNil(model.errorMessage)
            model.loadMore()
            await gate.resolve(3, with: .success(page(["new-last"], next: nil)))
            try await waitUntil { !model.isLoading }
            XCTAssertEqual(model.results.map(\.meeting.id), ["new-first", "new-last"])
            let requests = await gate.requests
            XCTAssertEqual(requests[3].speakerIDs, ["new-speaker"])
            XCTAssertEqual(requests[3].cursor, newCursor)
        }
    }

    func testCurrentRequestCancellationFinishesLoadingAndCanRetry() async throws {
        let gate = PageGate()
        let model = HomeModel(searchHandler: { try await gate.search($0) })
        model.query = "needle"
        model.filtersChanged()
        await gate.resolve(0, with: .failure(CancellationError()))
        try await waitUntil { !model.isLoading }
        XCTAssertNil(model.errorMessage)
        model.filtersChanged()
        await gate.resolve(1, with: .success(page(["recovered"], next: nil)))
        try await waitUntil { !model.isLoading }
        XCTAssertEqual(model.results.map(\.meeting.id), ["recovered"])
    }

    func testClearingAndInvalidDatesInvalidateInFlightPagesIncludingFailures() async throws {
        for invalidDates in [false, true] {
            for fails in [false, true] {
                let gate = PageGate()
                let model = HomeModel(searchHandler: { try await gate.search($0) })
                model.query = "needle"
                let first = model.resetAndSearch()
                await gate.resolve(0, with: .success(page(["first"], next: makeCursor("old"))))
                await first?.value
                let pending = model.loadMore()
                await gate.waitForRequest(1)
                if invalidDates {
                    model.usesDateRange = true
                    model.startDate = Date(timeIntervalSince1970: 200_000)
                    model.endDate = Date(timeIntervalSince1970: 100_000)
                    model.filtersChanged()
                } else {
                    model.clearFilters()
                }
                XCTAssertFalse(model.isLoading)
                await gate.resolve(1, with: fails ? .failure(PageError.failed) : .success(page(["stale"], next: nil)))
                await pending?.value
                XCTAssertFalse(model.isLoading)
                XCTAssertFalse(model.hasLoaded)
                XCTAssertTrue(model.results.isEmpty)
                XCTAssertNil(model.errorMessage)
                XCTAssertNil(model.nextCursor)
            }
        }
    }

    func testRepeatedSuccessfulCursorIsSuppressed() async throws {
        let gate = PageGate()
        let model = HomeModel(searchHandler: { try await gate.search($0) })
        let cursor = makeCursor("repeated")
        model.query = "needle"
        model.filtersChanged()
        await gate.resolve(0, with: .success(page(["one"], next: cursor)))
        try await waitUntil { !model.isLoading }
        model.loadMore()
        await gate.resolve(1, with: .success(page(["one", "two"], next: cursor)))
        try await waitUntil { !model.isLoading }
        model.loadMore()
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.nextCursor, "A repeated successful cursor must not leave a dead load-more button")
        XCTAssertEqual(model.results.map(\.meeting.id), ["one", "two"])
    }

    private enum PageError: Error { case failed }

    private actor PageGate {
        private(set) var requests: [SearchQuery] = []
        private var pending: [Int: CheckedContinuation<SearchPage, any Error>] = [:]
        private var entered: [Int: CheckedContinuation<Void, Never>] = [:]

        func search(_ query: SearchQuery) async throws -> SearchPage {
            let index = requests.count
            requests.append(query)
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                entered.removeValue(forKey: index)?.resume()
            }
        }

        func waitForRequest(_ index: Int) async {
            if requests.count > index { return }
            await withCheckedContinuation { entered[index] = $0 }
        }

        func resolve(_ index: Int, with result: Result<SearchPage, any Error>) async {
            await waitForRequest(index)
            pending.removeValue(forKey: index)?.resume(with: result)
        }
    }

    private func makeCursor(_ id: String) -> SearchCursor {
        try! JSONDecoder().decode(
            SearchCursor.self,
            from: Data(#"{"startedAt":0,"meetingID":"\#(id)","queryKey":"test"}"#.utf8)
        )
    }

    private func page(_ ids: [String], next: SearchCursor?) -> SearchPage {
        SearchPage(
            results: ids.map { SearchResult(meeting: makeMeeting(id: $0, title: $0), participants: [], hits: []) },
            nextCursor: next
        )
    }

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

    func testRealRepositoryPagesCombinedDateSpeakerAndTitleVersusUtteranceHits() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let utterances = UtteranceRepository(database)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        for id in ["alex", "bob"] {
            try await speakers.upsert(Speaker(id: id, anonymousName: id, originDeviceId: "test"))
        }
        for index in 0..<33 {
            let id = String(format: "meeting-%02d", index)
            let title = index.isMultiple(of: 2) ? "needle title" : "Planning"
            let meeting = Meeting(
                id: id, title: title,
                startedAt: day.addingTimeInterval(index == 32 ? -3_600 : Double(index * 60)),
                originDeviceId: "test"
            )
            try await meetings.insert(meeting)
            for (position, speaker) in ["alex", "bob"].enumerated() where index != 30 || speaker == "bob" {
                try await speakers.assignDisplayIndex(
                    meetingId: id, speakerId: speaker, displayIndex: position, deviceId: "test"
                )
            }
            try await utterances.append([
                Utterance(
                    id: "\(id)-bob", meetingId: id, startMs: 100, endMs: 200,
                    text: "needle spoken by Bob", speakerId: "bob", originDeviceId: "test"
                ),
                Utterance(
                    id: "\(id)-alex", meetingId: id, startMs: 300, endMs: 500,
                    text: index < 30 && !index.isMultiple(of: 2) ? "needle spoken by Alex" : "quiet",
                    speakerId: index == 30 ? "bob" : "alex", originDeviceId: "test"
                )
            ])
        }
        let repository = SearchRepository(database)
        let model = HomeModel(searchHandler: { try await repository.search($0) })
        model.query = "needle"
        model.speakerIDs = ["alex"]
        model.usesDateRange = true
        model.startDate = day
        model.endDate = day
        model.filtersChanged()
        try await waitUntil { !model.isLoading }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.results.count, 25)
        XCTAssertNotNil(model.nextCursor)
        model.loadMore()
        try await waitUntil { !model.isLoading }
        XCTAssertEqual(model.results.map(\.meeting.id), (0..<30).reversed().map { String(format: "meeting-%02d", $0) })
        XCTAssertNil(model.nextCursor)
        for result in model.results {
            let index = Int(result.meeting.id.suffix(2))!
            if index.isMultiple(of: 2) {
                XCTAssertTrue(result.titleMatched)
                XCTAssertTrue(result.hits.isEmpty, "Bob's text must not be attributed to filtered Alex")
            } else {
                XCTAssertFalse(result.titleMatched)
                XCTAssertEqual(result.hits.map(\.speakerId), ["alex"])
                XCTAssertEqual(result.hits.map(\.startMs), [300])
            }
        }
        model.query = ""
        model.filtersChanged()
        try await waitUntil { !model.isLoading }
        model.loadMore()
        try await waitUntil { !model.isLoading }
        XCTAssertEqual(model.results.count, 31, "Speaker-only includes Alex's quiet participation")
        XCTAssertTrue(model.results.contains { $0.meeting.id == "meeting-31" })
        XCTAssertFalse(model.results.contains { $0.meeting.id == "meeting-30" || $0.meeting.id == "meeting-32" })
        XCTAssertTrue(model.results.allSatisfy { !$0.titleMatched && $0.hits.isEmpty })
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

    func testInclusiveFallDSTDayContainsTwentyFiveHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let model = HomeModel()
        model.startDate = calendar.date(from: DateComponents(year: 2025, month: 11, day: 2, hour: 4))!
        model.endDate = model.startDate
        let range = try XCTUnwrap(model.inclusiveDateRange(calendar: calendar))
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 25 * 60 * 60)
        XCTAssertTrue(range.contains(range.upperBound.addingTimeInterval(-0.001)))
        XCTAssertFalse(range.contains(range.upperBound))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("condition timed out"); return }
            await Task.yield()
        }
    }

    private func makeMeeting(id: String, title: String) -> Meeting {
        Meeting(id: id, title: title, startedAt: Date(timeIntervalSince1970: 1_700_000_000), originDeviceId: "test-device")
    }
}
