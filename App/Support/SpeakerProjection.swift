import Foundation
import GRDB
import OSLog
import struct FluidAudio.DiarizerSegment
import TranscriptCore

/// Only stage names and monotonic timings leave this process's identity pipeline.
enum LiveIdentityTiming {
    enum Stage: String {
        case asrEvent, publicationEvent, projectionRead, observationDelivery, rowUpdate
    }
    private static let logger = Logger(subsystem: "com.transcript", category: "LiveIdentityTiming")

    static func record(_ stage: Stage, since start: TimeInterval? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsedMs = start.map { max(0, now - $0) * 1_000 } ?? 0
        logger.debug("stage=\(stage.rawValue, privacy: .public) uptime_s=\(now, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public)")
    }
}

/// Both screens resolve the persisted utterance identity, never a remembered animal
/// name or a neighboring sentence. One database snapshot also makes renames atomic.
struct SpeakerProjection: Sendable {
    enum IdentificationProgress: Equatable, Sendable {
        case unassigned
        case pending
        case identifying

        @MainActor
        var text: String {
            switch self {
            case .unassigned: LocalizationManager.shared.text("Unknown speaker", table: "AcceptanceUI")
            case .pending: LocalizationManager.shared.text("Speaker identification pending", table: "SpeakerProjection")
            case .identifying: LocalizationManager.shared.text("Identifying speaker…", table: "AcceptanceUI")
            }
        }
    }

    let meeting: Meeting?
    let utterances: [Utterance]
    let speakers: [Speaker]
    let slots: [MeetingSpeaker]
    let analysisState: String?
    let speakersByID: [String: Speaker]
    var readStartedAt = ProcessInfo.processInfo.systemUptime
    private let identitiesByUtteranceID: [String: String]

    static let empty = SpeakerProjection(meeting: nil, utterances: [], speakers: [], slots: [])

    init(meeting: Meeting?, utterances: [Utterance], speakers: [Speaker], slots: [MeetingSpeaker], analysisState: String? = nil) {
        self.meeting = meeting
        self.utterances = utterances
        self.speakers = speakers
        self.slots = slots
        self.analysisState = analysisState
        speakersByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        identitiesByUtteranceID = Dictionary(uniqueKeysWithValues: utterances.compactMap { utterance in
            utterance.speakerId.map { (utterance.id, $0) }
        })
    }

    var observedSpeakers: [Speaker] {
        let observed = Set(utterances.filter { $0.endMs > $0.startMs }.compactMap(\.speakerId))
        return speakers.filter { observed.contains($0.id) }
    }

    var extentMs: Int {
        // Captured-frame duration wins once published. ASR timestamps are only a
        // display fallback while archive metadata is not yet available.
        if let duration = meeting?.durationMs, duration > 0 { return duration }
        return max(utterances.map(\.endMs).max() ?? 0, 0)
    }

    var hasDurableArchive: Bool {
        guard let meeting else { return false }
        return meeting.state != .recording && meeting.durationMs >= 0
            && !(meeting.audioFileName?.isEmpty ?? true)
            && !(meeting.audioSHA256?.isEmpty ?? true)
            && (meeting.audioByteCount ?? 0) > 0
    }

    var identificationProgress: IdentificationProgress? {
        switch analysisState {
        case "pending", "rerun": .pending
        case "running": .identifying
        case nil: nil
        default: .unassigned
        }
    }

    func speaker(utteranceID: String) -> Speaker? {
        guard let id = identitiesByUtteranceID[utteranceID] else { return nil }
        return speakersByID[id]
    }

    static func fetch(database: AppDatabase, meetingID: String) async throws -> Self {
        try await database.reader.read { db in try read(db, meetingID: meetingID) }
    }

    static func stableAssignments(
        utterances: [Utterance], finalized: [DiarizerSegment], identitiesBySlot: [Int: String]
    ) -> [String: String] {
        var assignments: [String: String] = [:]
        let finalizedThroughMs = Int(((finalized.map(\.endTime).max() ?? 0) * 1_000).rounded())
        for utterance in utterances where utterance.speakerId == nil {
            // A finalized prefix cannot identify an entire sentence whose later
            // turns are still tentative. Multiple slots may represent one person.
            guard utterance.endMs <= finalizedThroughMs,
                  let identity = SpeakerOverlapAssigner.speakerID(
                    utteranceStartMs: utterance.startMs, utteranceEndMs: utterance.endMs,
                    segments: finalized, identitiesBySlot: identitiesBySlot
                  ) else { continue }
            assignments[utterance.id] = identity
        }
        return assignments
    }

    static func ensureLiveSlots(
        database: AppDatabase, meetingID: String, indexes: [Int], deviceID: String
    ) async throws -> Self {
        try await database.writer.write { db in
            let snapshot = try read(db, meetingID: meetingID)
            guard snapshot.meeting != nil, snapshot.analysisState == nil else { return snapshot }
            let occupied = Set(snapshot.slots.map(\.displayIndex))
            for index in Set(indexes).sorted() where !occupied.contains(index) {
                let used = try String.fetchAll(db, sql: "SELECT anonymousName FROM speaker")
                let speaker = Speaker(
                    anonymousName: AnonymousNameGenerator.nextName(usedNames: used),
                    colorIndex: try Speaker.fetchCount(db) % 12, originDeviceId: deviceID
                )
                try speaker.insert(db)
                try MeetingSpeaker(
                    meetingId: meetingID, speakerId: speaker.id, displayIndex: index, originDeviceId: deviceID
                ).insert(db)
            }
            return try read(db, meetingID: meetingID)
        }
    }

    /// Late live evidence may fill an unresolved row, but must never undo an
    /// authoritative assignment or a slot change made by offline analysis.
    static func backfillUnresolved(
        database: AppDatabase, snapshot: Self, assignments: [String: String], deviceID: String
    ) async throws {
        guard let meetingID = snapshot.meeting?.id, !assignments.isEmpty else { return }
        try await database.writer.write { db in
            // Once queued, offline analysis owns the assignments, including its
            // deliberately unresolved rows. Never restart live identity enrollment.
            guard try analysisState(db, meetingID: meetingID) == nil else { return }
            let currentSlots = try MeetingSpeaker
                .filter(MeetingSpeaker.Columns.meetingId == meetingID)
                .order(MeetingSpeaker.Columns.displayIndex).fetchAll(db)
            guard currentSlots == snapshot.slots else { return }
            let identities = Set(currentSlots.map(\.speakerId))
            for expected in snapshot.utterances where expected.speakerId == nil {
                guard let speakerID = assignments[expected.id],
                      identities.contains(speakerID),
                      var current = try Utterance.fetchOne(db, key: expected.id),
                      current.meetingId == meetingID, current.speakerId == nil,
                      current.revision == expected.revision else { continue }
                current.speakerId = speakerID
                current.revision += 1
                current.updatedAt = Date()
                current.originDeviceId = deviceID
                try current.update(db)
            }
        }
    }

    @MainActor
    static func observe(
        database: AppDatabase, meetingID: String,
        onChange: @MainActor (Self) -> Void
    ) async throws {
        let observation = ValueObservation.tracking { db in try read(db, meetingID: meetingID) }
        for try await snapshot in observation.values(in: database.reader) {
            try Task.checkCancellation()
            LiveIdentityTiming.record(.observationDelivery, since: snapshot.readStartedAt)
            onChange(snapshot)
        }
    }

    private static func read(_ db: Database, meetingID: String) throws -> Self {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let meeting = try Meeting.fetchOne(db, key: meetingID)
        let utterances = try Utterance
            .filter(Utterance.Columns.meetingId == meetingID)
            .order(Utterance.Columns.startMs).fetchAll(db)
        let slots = try MeetingSpeaker
            .filter(MeetingSpeaker.Columns.meetingId == meetingID)
            .order(MeetingSpeaker.Columns.displayIndex).fetchAll(db)
        // Include referenced global identities even if a legacy row has no slot link.
        let speakers = try Speaker.fetchAll(db, sql: """
            SELECT speaker.* FROM speaker
            WHERE id IN (SELECT speakerId FROM meetingSpeaker WHERE meetingId = ?)
               OR id IN (SELECT speakerId FROM utterance WHERE meetingId = ?)
            ORDER BY id
            """, arguments: [meetingID, meetingID])
        let positions = Dictionary(uniqueKeysWithValues: slots.map { ($0.speakerId, $0.displayIndex) })
        var snapshot = Self(
            meeting: meeting, utterances: utterances,
            speakers: speakers.sorted {
                (positions[$0.id] ?? Int.max, $0.id) < (positions[$1.id] ?? Int.max, $1.id)
            },
            slots: slots, analysisState: try analysisState(db, meetingID: meetingID)
        )
        snapshot.readStartedAt = startedAt
        LiveIdentityTiming.record(.projectionRead, since: startedAt)
        return snapshot
    }

    private static func analysisState(_ db: Database, meetingID: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT state FROM speakerAnalysisJob WHERE meetingId = ?", arguments: [meetingID])
    }
}
