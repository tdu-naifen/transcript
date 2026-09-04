import Foundation
import GRDB

/// Derives `meeting.localeIdentifier` from the per-utterance language tags that
/// Nemotron emits (PLAN §9.2 — meeting level is a summary, utterance level is truth).
enum PrimaryLanguage {
    /// Most-spoken language of a meeting, weighted by utterance duration.
    /// Ties break on utterance count, then alphabetically, so the result is stable.
    static func derive(_ db: Database, meetingId: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT localeIdentifier
            FROM utterance
            WHERE meetingId = ? AND localeIdentifier IS NOT NULL
            GROUP BY localeIdentifier
            ORDER BY SUM(MAX(endMs - startMs, 0)) DESC, COUNT(*) DESC, localeIdentifier ASC
            LIMIT 1
            """, arguments: [meetingId])
    }
}
