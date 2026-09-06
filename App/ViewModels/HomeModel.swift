import Foundation
import Observation
import TranscriptCore

/// Owns the Home search request lifecycle.  A new filter generation cancels the
/// previous request and invalidates its result, so a slow page cannot overwrite
/// a newer query.
@MainActor
@Observable
final class HomeModel {
    typealias SearchHandler = @Sendable (SearchQuery) async throws -> SearchPage

    var query = ""
    var speakerIDs: Set<String> = []
    var usesDateRange = false
    var startDate = Calendar.current.startOfDay(for: Date())
    var endDate = Date()

    private(set) var results: [SearchResult] = []
    private(set) var nextCursor: SearchCursor?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    private var generation = 0
    private var requestTask: Task<Void, Never>?
    private let searchHandler: SearchHandler?
    private var loadedMeetingIDs: Set<String> = []
    private var requestedCursors: Set<SearchCursor> = []

    init(searchHandler: SearchHandler? = nil) {
        self.searchHandler = searchHandler
    }

    var hasSearchConditions: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !speakerIDs.isEmpty || usesDateRange
    }

    var isDateRangeInvalid: Bool {
        usesDateRange && inclusiveDateRange() == nil
    }

    /// Uses calendar arithmetic rather than 86400 seconds, preserving DST
    /// transitions while including the selected end date.
    func inclusiveDateRange(calendar: Calendar = .current) -> Range<Date>? {
        let lower = calendar.startOfDay(for: startDate)
        let lastDay = calendar.startOfDay(for: endDate)
        guard lower <= lastDay,
              let upper = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        return lower..<upper
    }

    func clearFilters() {
        query = ""
        speakerIDs = []
        usesDateRange = false
        resetAndSearch()
    }

    func filtersChanged() {
        resetAndSearch()
    }

    @discardableResult
    func resetAndSearch() -> Task<Void, Never>? {
        generation += 1
        requestTask?.cancel()
        nextCursor = nil
        results = []
        loadedMeetingIDs = []
        requestedCursors = []
        errorMessage = nil
        hasLoaded = false
        isLoading = false
        guard hasSearchConditions, !isDateRangeInvalid, let searchHandler else { return nil }
        return startRequest(handler: searchHandler, cursor: nil, generation: generation)
    }

    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard !isLoading, let cursor = nextCursor, let searchHandler else { return nil }
        guard !requestedCursors.contains(cursor) else { return nil }
        return startRequest(handler: searchHandler, cursor: cursor, generation: generation)
    }

    private func startRequest(handler: @escaping SearchHandler, cursor: SearchCursor?, generation: Int) -> Task<Void, Never> {
        isLoading = true
        let request = SearchQuery(
            text: query.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: .all,
            startedAt: usesDateRange ? inclusiveDateRange() : nil,
            speakerIDs: speakerIDs,
            limit: 25,
            cursor: cursor
        )
        let task = Task { [weak self] in
            defer {
                if let self, self.generation == generation { self.isLoading = false }
            }
            do {
                let page = try await handler(request)
                guard !Task.isCancelled else { return }
                guard let self, self.generation == generation else { return }
                if let cursor { self.requestedCursors.insert(cursor) }
                let unique = page.results.filter { self.loadedMeetingIDs.insert($0.meeting.id).inserted }
                if cursor == nil { self.results = unique } else { self.results += unique }
                self.nextCursor = page.nextCursor.flatMap {
                    self.requestedCursors.contains($0) ? nil : $0
                }
                self.hasLoaded = true
                self.errorMessage = nil
            } catch is CancellationError {
                guard let self, self.generation == generation else { return }
                self.hasLoaded = true
            } catch {
                guard let self, self.generation == generation else { return }
                self.errorMessage = error.localizedDescription
                self.hasLoaded = true
            }
        }
        requestTask = task
        return task
    }
}
