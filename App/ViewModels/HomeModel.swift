import Foundation
import Observation

@MainActor
@Observable
final class HomeModel {
    var query = ""
    var speakerIDs: Set<String> = []
    var usesDateRange = false
    var startDate = Calendar.current.startOfDay(for: Date())
    var endDate = Date()

    var hasSearchConditions: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !speakerIDs.isEmpty || usesDateRange
    }

    var isDateRangeInvalid: Bool {
        usesDateRange && inclusiveDateRange() == nil
    }

    /// Both selected days are included, including 23/25-hour daylight-saving days.
    /// The search owner has not frozen its API yet; no query is sent from this model.
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
    }
}
