import Foundation
import GRDB

public enum AnalysisKind: String, Codable, Sendable, CaseIterable {
    case qa
    case metadataTags
}

/// What the Mac hands to ``AnalysisResultRepository/record(_:)``, and the wire form of
/// PLAN §3c's `analysis-result` message.
///
/// `revision` is deliberately absent: PLAN §3.2.1 legalizes `analyzed → queued`, so the
/// same `(meetingId, kind)` is re-analyzed repeatedly and a caller-supplied revision could
/// go backwards, making `latest()` return a stale row. The database assigns it (PLAN §9.4).
/// Because this is the only public `Codable` type of the pair, a decoded message has no
/// syntax for expressing a revision at all — a forged one cannot even be represented.
public struct AnalysisResultDraft: Codable, Hashable, Sendable {
    public var id: String
    public var meetingId: String
    public var kind: AnalysisKind
    public var payloadJSON: String
    public var producedByDeviceId: String
    public var producedAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        kind: AnalysisKind,
        payloadJSON: String,
        producedByDeviceId: String,
        producedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.producedByDeviceId = producedByDeviceId
        self.producedAt = producedAt
    }
}

/// Layer E: produced on the Mac, read-only on the iPhone. The only table the Mac
/// owns (PLAN §3.1 — global re-clustering is out of scope, §9.1).
///
/// Deliberately **not** `Decodable` and **not** a GRDB record: both would expose a public
/// initializer that takes `revision` verbatim, and PLAN §3c makes JSON decoding of an
/// analysis result an actual ingestion path, so such an initializer would accept a
/// bug- or attacker-supplied revision. The type is therefore only obtainable from the
/// database — fetched, or returned by ``AnalysisResultRepository/record(_:)`` once it
/// stamped a monotonic `revision`. Send it with ``draft`` and let the receiving database
/// assign its own revision.
public struct AnalysisResult: Encodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let meetingId: String
    public let kind: AnalysisKind
    public let payloadJSON: String
    public let producedByDeviceId: String
    public let producedAt: Date
    /// Monotonic within `(meetingId, kind)`, assigned by the database.
    public let revision: Int

    static let databaseTableName = "analysisResult"

    init(draft: AnalysisResultDraft, revision: Int) {
        self.id = draft.id
        self.meetingId = draft.meetingId
        self.kind = draft.kind
        self.payloadJSON = draft.payloadJSON
        self.producedByDeviceId = draft.producedByDeviceId
        self.producedAt = draft.producedAt
        self.revision = revision
    }

    init(row: Row) throws {
        guard let kind = AnalysisKind(rawValue: row["kind"]) else {
            throw RepositoryError.unknownAnalysisKind(rawValue: row["kind"])
        }
        self.id = row["id"]
        self.meetingId = row["meetingId"]
        self.kind = kind
        self.payloadJSON = row["payloadJSON"]
        self.producedByDeviceId = row["producedByDeviceId"]
        self.producedAt = row["producedAt"]
        self.revision = row["revision"]
    }

    /// The wire form. Revision is intentionally dropped: the receiving database assigns
    /// its own, keeping monotonicity a local invariant instead of a trusted input.
    public var draft: AnalysisResultDraft {
        AnalysisResultDraft(
            id: id,
            meetingId: meetingId,
            kind: kind,
            payloadJSON: payloadJSON,
            producedByDeviceId: producedByDeviceId,
            producedAt: producedAt
        )
    }
}
