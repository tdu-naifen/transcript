import Foundation
import GRDB

/// Layer E is Mac-owned; the iPhone only ever ingests what the Mac produced.
public struct AnalysisResultRepository: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// Assigns `revision = MAX(revision) + 1` scoped to `(meetingId, kind)` and inserts,
    /// both inside one write transaction. Writes are serialized by SQLite, and
    /// `analysisResult_on_meetingId_kind_revision` is UNIQUE, so a racing writer can
    /// neither observe a stale maximum nor land a duplicate revision (PLAN §9.4).
    ///
    /// This is the only insert path — ``AnalysisResult`` is not a GRDB record — so a
    /// revision can never arrive from outside the module.
    @discardableResult
    public func record(
        _ draft: AnalysisResultDraft,
        inputRevision: String? = nil,
        modelFingerprint: String? = nil,
        preprocessing: String? = nil
    ) async throws -> AnalysisResult {
        try await database.writer.write { db in
            if inputRevision != nil || modelFingerprint != nil || preprocessing != nil {
                guard let inputRevision, let modelFingerprint, let preprocessing else {
                    throw AutomaticSyncWire.Failure.invalid
                }
                guard try AutomaticSyncRepository.transcriptRevision(db, meetingID: draft.meetingId) == inputRevision else {
                    throw AutomaticSyncWire.Failure.staleRevision
                }
                try AutomaticSyncRepository.captureAnalysis(db, draft: draft, inputRevision: inputRevision,
                                                            modelFingerprint: modelFingerprint, preprocessing: preprocessing)
            }
            let next = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(revision), 0) + 1 FROM analysisResult
                WHERE meetingId = ? AND kind = ?
                """, arguments: [draft.meetingId, draft.kind.rawValue]) ?? 1
            let result = AnalysisResult(draft: draft, revision: next)
            try db.execute(
                sql: """
                    INSERT INTO analysisResult
                    (id, meetingId, kind, payloadJSON, producedByDeviceId, producedAt, revision)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    result.id, result.meetingId, result.kind.rawValue, result.payloadJSON,
                    result.producedByDeviceId, result.producedAt, result.revision
                ]
            )
            return result
        }
    }

    public func latest(meetingId: String, kind: AnalysisKind) async throws -> AnalysisResult? {
        try await database.reader.read { db in
            let input = try AutomaticSyncRepository.transcriptRevision(db, meetingID: meetingId)
            return try Row.fetchOne(db, sql: """
                SELECT a.* FROM analysisResult a
                LEFT JOIN automaticSyncAnalysisProvenance p ON p.analysisID=a.id
                WHERE a.meetingId = ? AND a.kind = ? AND (p.analysisID IS NULL OR p.inputRevision=?)
                ORDER BY a.revision DESC LIMIT 1
                """, arguments: [meetingId, kind.rawValue, input])
                .map(AnalysisResult.init(row:))
        }
    }

    public func fetchAll(meetingId: String) async throws -> [AnalysisResult] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM analysisResult WHERE meetingId = ? ORDER BY producedAt DESC
                """, arguments: [meetingId])
                .map(AnalysisResult.init(row:))
        }
    }
}
