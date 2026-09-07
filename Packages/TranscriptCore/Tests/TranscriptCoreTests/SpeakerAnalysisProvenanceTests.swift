import Foundation
import GRDB
import XCTest
@testable import TranscriptCore

@MainActor
final class SpeakerAnalysisProvenanceTests: XCTestCase {
    private func fixture() async throws -> (AppDatabase, String, [Utterance], String) {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Provenance", startedAt: Date(), state: .recorded, originDeviceId: "qa")
        try await MeetingRepository(db).insert(meeting)
        let repository = UtteranceRepository(db)
        try await repository.append([Utterance(meetingId: meeting.id, startMs: 0, endMs: 2000,
                                              text: "Original", originDeviceId: "qa")])
        let rows = try await repository.fetch(meetingId: meeting.id)
        let result = try await SpeakerAnalysisRepository(db).apply(
            meetingID: meeting.id, expectedUtterances: rows, slotsByUtterance: [rows[0].id: 0],
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 2)], modelIdentifier: "test", deviceID: "qa")
        return (db, meeting.id, try await repository.fetch(meetingId: meeting.id), try XCTUnwrap(result[0]?.id))
    }

    private func markerCount(_ db: AppDatabase) async throws -> Int {
        try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM speakerAnalysisAutomaticAssignment") ?? 0 }
    }

    private func unknown(_ db: AppDatabase, _ meeting: String, _ rows: [Utterance]) async throws {
        try await SpeakerAnalysisRepository(db).apply(
            meetingID: meeting, expectedUtterances: rows, slotsByUtterance: [:],
            unknownUtteranceIDs: Set(rows.map(\.id)), voices: [], modelIdentifier: "test", deviceID: "qa")
    }

    func testManualSameIDAndNoOpAutomaticPassDoNotRecreateProvenance() async throws {
        let (db, meeting, rows, speaker) = try await fixture()
        try await UtteranceRepository(db).assignSpeaker(utteranceId: rows[0].id, speakerId: speaker, deviceId: "manual")
        let expected = try await UtteranceRepository(db).fetch(meetingId: meeting)
        try await SpeakerAnalysisRepository(db).apply(
            meetingID: meeting, expectedUtterances: expected, slotsByUtterance: [rows[0].id: 0],
            voices: [.init(slot: 0, embedding: nil, cleanDuration: 0)], modelIdentifier: "test", deviceID: "qa")
        let markers = try await markerCount(db)
        XCTAssertEqual(markers, 0)
        try await unknown(db, meeting, expected)
        let after = try await UtteranceRepository(db).fetch(meetingId: meeting)
        XCTAssertEqual(after, expected)
    }

    func testAutomaticNoOpRetainsProofButAnyUtteranceUpdateInvalidatesIt() async throws {
        let (db, meeting, rows, _) = try await fixture()
        try await SpeakerAnalysisRepository(db).apply(
            meetingID: meeting, expectedUtterances: rows, slotsByUtterance: [rows[0].id: 0],
            voices: [.init(slot: 0, embedding: nil, cleanDuration: 0)], modelIdentifier: "test", deviceID: "qa")
        let retained = try await markerCount(db)
        XCTAssertEqual(retained, 1)
        try await db.writer.write { try $0.execute(sql: "UPDATE utterance SET text = text WHERE id = ?", arguments: [rows[0].id]) }
        let invalidated = try await markerCount(db)
        XCTAssertEqual(invalidated, 0)
        try await unknown(db, meeting, rows)
        let after = try await UtteranceRepository(db).fetch(meetingId: meeting)
        XCTAssertEqual(after, rows)
    }

    func testNamedAutomaticAssignmentAndGlobalTemplateArePreserved() async throws {
        let (db, meeting, rows, speaker) = try await fixture()
        let speakers = SpeakerRepository(db)
        let before = try await speakers.embeddings(forSpeaker: speaker)
        try await speakers.rename(id: speaker, displayName: "User name", deviceId: "manual")
        try await unknown(db, meeting, rows)
        let after = try await UtteranceRepository(db).fetch(meetingId: meeting)
        let templates = try await speakers.embeddings(forSpeaker: speaker)
        XCTAssertEqual(after, rows)
        XCTAssertEqual(templates, before)
    }

    func testStaleAndCancelledResultsPreserveProofThenValidUnknownConsumesIt() async throws {
        let (db, meeting, rows, _) = try await fixture()
        var stale = rows
        stale[0].revision -= 1
        do { try await unknown(db, meeting, stale); XCTFail("Stale") }
        catch VoiceprintBindingError.staleExpectation {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await self.unknown(db, meeting, rows)
        }
        do { try await task.value; XCTFail("Cancelled") } catch is CancellationError {}
        let markers = try await markerCount(db)
        XCTAssertEqual(markers, 1)
        try await unknown(db, meeting, rows)
        let consumed = try await markerCount(db)
        let after = try await UtteranceRepository(db).fetch(meetingId: meeting)
        XCTAssertEqual(consumed, 0)
        XCTAssertNil(after[0].speakerId)
    }

    func testDeletionCascadesProof() async throws {
        let (db, meeting, _, _) = try await fixture()
        try await MeetingRepository(db).delete(id: meeting)
        let markers = try await markerCount(db)
        XCTAssertEqual(markers, 0)
    }

    func testV10UpgradeDoesNotBackfillLegacyAssignments() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v9_local_immutable_meeting_copy_outbox")
        let meeting = Meeting(title: "Legacy", startedAt: Date(), state: .recorded, originDeviceId: "qa")
        let speaker = Speaker(anonymousName: "Legacy animal", colorIndex: 0, originDeviceId: "qa")
        let row = Utterance(meetingId: meeting.id, startMs: 0, endMs: 2000, text: "Legacy",
                            speakerId: speaker.id, revision: 2, originDeviceId: "qa")
        try await queue.write { db in
            try meeting.insert(db)
            try speaker.insert(db)
            try row.insert(db)
        }
        let db = try AppDatabase(queue)
        let expected = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        let markers = try await markerCount(db)
        XCTAssertEqual(markers, 0)
        try await unknown(db, meeting.id, expected)
        let after = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertEqual(after, expected)
    }
}
