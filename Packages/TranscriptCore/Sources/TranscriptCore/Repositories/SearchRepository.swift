import Foundation
import GRDB

/// Which indexed meeting text participates in a search.
public enum SearchScope: String, Codable, Sendable {
    case title
    case transcript
    case all
}

/// Opaque position in the ordering `startedAt DESC, id DESC`.
/// Reuse is rejected when any filter changes.
public struct SearchCursor: Codable, Hashable, Sendable {
    fileprivate let startedAt: Date
    fileprivate let meetingID: String
    fileprivate let queryKey: String
}

public struct SearchQuery: Sendable {
    public var text: String
    public var scope: SearchScope
    public var startedAt: Range<Date>?
    public var speakerIDs: Set<String>
    public var limit: Int
    public var cursor: SearchCursor?

    public init(
        text: String = "",
        scope: SearchScope = .all,
        startedAt: Range<Date>? = nil,
        speakerIDs: Set<String> = [],
        limit: Int = 25,
        cursor: SearchCursor? = nil
    ) {
        self.text = text
        self.scope = scope
        self.startedAt = startedAt
        self.speakerIDs = speakerIDs
        self.limit = limit
        self.cursor = cursor
    }
}

public struct SearchParticipant: Hashable, Sendable {
    public let speaker: Speaker
    public let displayIndex: Int

    public init(speaker: Speaker, displayIndex: Int) {
        self.speaker = speaker
        self.displayIndex = displayIndex
    }
}

/// Exact utterance hit. Offsets are milliseconds in the meeting audio.
public struct SearchTextHit: Hashable, Sendable {
    public let utteranceId: String
    public let speakerId: String?
    public let text: String
    public let startMs: Int
    public let endMs: Int

    public init(utteranceId: String, speakerId: String?, text: String, startMs: Int, endMs: Int) {
        self.utteranceId = utteranceId
        self.speakerId = speakerId
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct SearchResult: Sendable {
    public let meeting: Meeting
    public let participants: [SearchParticipant]
    public let hits: [SearchTextHit]
    public let titleMatched: Bool

    public init(
        meeting: Meeting,
        participants: [SearchParticipant],
        hits: [SearchTextHit],
        titleMatched: Bool = false
    ) {
        self.meeting = meeting
        self.participants = participants
        self.hits = hits
        self.titleMatched = titleMatched
    }
}

public struct SearchPage: Sendable {
    public let results: [SearchResult]
    public let nextCursor: SearchCursor?
}

public enum SearchRepositoryError: Error, Equatable, Sendable {
    case cursorDoesNotMatchQuery
}

/// Indexed literal-substring meeting search with bounded keyset pages.
/// ASCII letters are case-insensitive (SQLite `lower`); non-ASCII scalars match exactly,
/// without case folding or Unicode normalization. FTS supplies a candidate superset only.
public struct SearchRepository: Sendable {
    private static let maximumLimit = 50
    private static let maximumHitsPerMeeting = 5
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    public func search(_ query: SearchQuery) async throws -> SearchPage {
        let normalized = NormalizedQuery(query)
        guard query.cursor?.queryKey == nil || query.cursor?.queryKey == normalized.key else {
            throw SearchRepositoryError.cursorDoesNotMatchQuery
        }

        return try await database.reader.read { db in
            var arguments: [(any DatabaseValueConvertible)?] = []
            var predicates: [String] = []

            if let dates = normalized.startedAt {
                predicates.append("meeting.startedAt >= ? AND meeting.startedAt < ?")
                arguments.append(dates.lowerBound)
                arguments.append(dates.upperBound)
            }
            if !normalized.speakerIDs.isEmpty {
                predicates.append("EXISTS (SELECT 1 FROM meetingSpeaker ms WHERE ms.meetingId = meeting.id AND ms.speakerId IN (\(Self.placeholders(normalized.speakerIDs.count))))")
                normalized.speakerIDs.forEach { arguments.append($0) }
            }
            if !normalized.text.isEmpty {
                var documents = "searchDocument document"
                if normalized.usesTrigrams {
                    // CROSS JOIN fixes the loop order: FTS postings -> document rowid, never
                    // one document scan per meeting. IN deduplicates the resulting meeting IDs.
                    // Default trigram folding includes ASCII folding and preserves scalar order:
                    // it may add Unicode case variants, which the literal verifier rejects.
                    // NUL truncates tokenization, hence the partial-index exception below.
                    documents = """
                        (SELECT rowid FROM searchDocumentFTS WHERE searchDocumentFTS MATCH ?
                         UNION SELECT rowid FROM searchDocument WHERE instr(text, char(0)) > 0) candidates
                        CROSS JOIN searchDocument document ON document.rowid = candidates.rowid
                        """
                    arguments.append(Self.ftsLiteral(normalized.text))
                }
                let textPredicate = Self.textPredicate(
                    normalized, arguments: &arguments, documentAlias: "document"
                )
                predicates.append("meeting.id IN (SELECT document.meetingId FROM \(documents) WHERE \(textPredicate))")
            }
            if let cursor = query.cursor {
                predicates.append("(meeting.startedAt < ? OR (meeting.startedAt = ? AND meeting.id < ?))")
                arguments.append(cursor.startedAt)
                arguments.append(cursor.startedAt)
                arguments.append(cursor.meetingID)
            }

            let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
            arguments.append(normalized.limit + 1)
            let meetings = try Meeting.fetchAll(
                db,
                sql: "SELECT meeting.* FROM meeting \(whereClause) ORDER BY meeting.startedAt DESC, meeting.id DESC LIMIT ?",
                arguments: StatementArguments(arguments)
            )
            let hasNext = meetings.count > normalized.limit
            let pageMeetings = Array(meetings.prefix(normalized.limit))
            let meetingIDs = pageMeetings.map(\.id)
            let participants = try Self.fetchParticipants(db, meetingIDs: meetingIDs)
            let hits = try Self.fetchHits(db, query: normalized, meetingIDs: meetingIDs)
            let titleMatches = try Self.fetchTitleMatches(db, query: normalized, meetingIDs: meetingIDs)
            let results = pageMeetings.map { meeting in
                SearchResult(
                    meeting: meeting,
                    participants: participants[meeting.id] ?? [],
                    hits: hits[meeting.id] ?? [],
                    titleMatched: titleMatches.contains(meeting.id)
                )
            }
            let nextCursor = hasNext ? pageMeetings.last.map {
                SearchCursor(startedAt: $0.startedAt, meetingID: $0.id, queryKey: normalized.key)
            } : nil
            return SearchPage(results: results, nextCursor: nextCursor)
        }
    }

    private static func textPredicate(
        _ query: NormalizedQuery,
        arguments: inout [(any DatabaseValueConvertible)?],
        documentAlias: String
    ) -> String {
        var scopes: [String] = []
        if query.scope == .title || query.scope == .all {
            scopes.append("\(documentAlias).sourceKind = 'title'")
        }
        if query.scope == .transcript || query.scope == .all {
            var transcript = "\(documentAlias).sourceKind = 'utterance'"
            if !query.speakerIDs.isEmpty {
                transcript += " AND EXISTS (SELECT 1 FROM utterance hitUtterance WHERE hitUtterance.id = \(documentAlias).sourceId AND hitUtterance.speakerId IN (\(placeholders(query.speakerIDs.count))))"
            }
            scopes.append("(\(transcript))")
        }

        var predicate = "(\(scopes.joined(separator: " OR ")))"
        if !query.speakerIDs.isEmpty && (query.scope == .transcript || query.scope == .all) {
            arguments.append(contentsOf: query.speakerIDs)
        }
        // ponytail: 1–2 scalar searches scan indexed documents but never truncate candidates;
        // add a measured short n-gram index only if the dedicated Simulator benchmark requires it.
        predicate += " AND instr(lower(\(documentAlias).text), lower(?)) > 0"
        arguments.append(query.text)
        return predicate
    }

    private static func fetchParticipants(
        _ db: Database,
        meetingIDs: [String]
    ) throws -> [String: [SearchParticipant]] {
        guard !meetingIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT meetingSpeaker.meetingId AS participantMeetingId,
                   meetingSpeaker.displayIndex AS participantDisplayIndex, speaker.*
            FROM meetingSpeaker
            JOIN speaker ON speaker.id = meetingSpeaker.speakerId
            WHERE meetingSpeaker.meetingId IN (\(placeholders(meetingIDs.count)))
            ORDER BY meetingSpeaker.meetingId, meetingSpeaker.displayIndex, speaker.id
            """, arguments: StatementArguments(meetingIDs))
        return try Dictionary(grouping: rows, by: { $0["participantMeetingId"] as String })
            .mapValues { rows in
                try rows.map {
                    SearchParticipant(
                        speaker: try Speaker(row: $0),
                        displayIndex: $0["participantDisplayIndex"]
                    )
                }
            }
    }

    private static func fetchTitleMatches(
        _ db: Database,
        query: NormalizedQuery,
        meetingIDs: [String]
    ) throws -> Set<String> {
        guard !meetingIDs.isEmpty, !query.text.isEmpty, query.scope != .transcript else { return [] }
        let rows = try String.fetchAll(db, sql: """
            SELECT meetingId FROM searchDocument
            WHERE sourceKind = 'title'
              AND meetingId IN (\(placeholders(meetingIDs.count)))
              AND instr(lower(text), lower(?)) > 0
            """, arguments: StatementArguments(meetingIDs + [query.text]))
        return Set(rows)
    }

    private static func fetchHits(
        _ db: Database,
        query: NormalizedQuery,
        meetingIDs: [String]
    ) throws -> [String: [SearchTextHit]] {
        guard !meetingIDs.isEmpty, !query.text.isEmpty, query.scope != .title else { return [:] }
        var hits: [String: [SearchTextHit]] = [:]
        // At most 50 local queries, each producing at most five rows without a sort/window.
        // ponytail: rare hits can scan one page meeting's transcript; add a per-meeting
        // postings index only if measured latency requires it. No global hit materialization.
        for meetingID in meetingIDs {
            var arguments: [(any DatabaseValueConvertible)?] = [meetingID]
            var conditions = ["meetingId = ?"]
            if !query.speakerIDs.isEmpty {
                conditions.append("speakerId IN (\(placeholders(query.speakerIDs.count)))")
                arguments.append(contentsOf: query.speakerIDs)
            }
            conditions.append("instr(lower(text), lower(?)) > 0")
            arguments.append(query.text)
            arguments.append(maximumHitsPerMeeting)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, speakerId, text, startMs, endMs
                FROM utterance INDEXED BY utterance_on_meetingId_startMs_id
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY startMs, id
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            hits[meetingID] = rows.map {
                SearchTextHit(
                    utteranceId: $0["id"], speakerId: $0["speakerId"], text: $0["text"],
                    startMs: $0["startMs"], endMs: $0["endMs"]
                )
            }
        }
        return hits
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func ftsLiteral(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private struct NormalizedQuery {
        let text: String
        let scope: SearchScope
        let startedAt: Range<Date>?
        let speakerIDs: [String]
        let limit: Int
        let key: String

        // FTS stops at NUL. NUL-bearing queries scan literally; NUL-bearing documents
        // are unioned into ordinary FTS candidates via a small partial index.
        var usesTrigrams: Bool { text.unicodeScalars.count >= 3 && !text.contains("\u{0}") }

        init(_ query: SearchQuery) {
            text = query.text
            scope = query.scope
            startedAt = query.startedAt
            speakerIDs = query.speakerIDs.sorted()
            limit = min(max(query.limit, 1), maximumLimit)
            let components = [
                query.text, query.scope.rawValue,
                query.startedAt.map { String($0.lowerBound.timeIntervalSinceReferenceDate.bitPattern) } ?? "",
                query.startedAt.map { String($0.upperBound.timeIntervalSinceReferenceDate.bitPattern) } ?? ""
            ] + query.speakerIDs.sorted()
            key = components.map { "\($0.utf8.count):\($0)" }.joined()
        }
    }
}
