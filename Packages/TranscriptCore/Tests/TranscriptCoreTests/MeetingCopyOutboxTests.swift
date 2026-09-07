import Foundation
import GRDB
import XCTest
@testable import TranscriptCore

final class MeetingCopyOutboxTests: XCTestCase {
    func testV9QueueAtomicallyOwnsSnapshotAndRejectsDuplicate() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Self.meeting()
        try await MeetingRepository(database).insert(meeting)
        let repository = MeetingCopyOutbox(database)
        let snapshot = try await repository.snapshot(meetingID: meeting.id)
        let entry = try await enqueue(repository, snapshot)
        XCTAssertEqual(entry.state, "queued")
        XCTAssertNil(entry.receipt)
        let saved = try await repository.entry(id: entry.id)
        XCTAssertEqual(saved.manifest, Data("manifest".utf8))
        XCTAssertEqual(saved.transcript, Data("transcript".utf8))
        let original = try await repository.validate(id: entry.id)
        XCTAssertEqual(original, snapshot)
        do { _ = try await enqueue(repository, snapshot); XCTFail("Duplicate destination/meeting") }
        catch MeetingCopyOutbox.Failure.duplicate {}
    }

    func testStaleEnqueueAndSourceTriggerFailClosed() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Self.meeting()
        try await MeetingRepository(database).insert(meeting)
        let repository = MeetingCopyOutbox(database)
        let snapshot = try await repository.snapshot(meetingID: meeting.id)
        _ = try await MeetingRepository(database).rename(id: meeting.id, title: "New title", deviceId: "qa")
        do { _ = try await enqueue(repository, snapshot); XCTFail("Stale enqueue") }
        catch MeetingCopyOutbox.Failure.staleSnapshot {}
        let fresh = try await repository.snapshot(meetingID: meeting.id)
        let entry = try await enqueue(repository, fresh)
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 10, text: "New", originDeviceId: "qa")
        try await database.writer.write { db in try utterance.insert(db) }
        do { try await repository.assertPending(id: entry.id); XCTFail("Source changed") }
        catch MeetingCopyOutbox.Failure.staleSnapshot {}
        try await repository.retry(id: entry.id)
        let saved = try await repository.entry(id: entry.id)
        XCTAssertEqual(saved.state, "stale")
        XCTAssertEqual(saved.manifest, entry.manifest)
    }

    func testCancellationAndReceiptAreDistinctAtomicStates() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Self.meeting()
        try await MeetingRepository(database).insert(meeting)
        let repository = MeetingCopyOutbox(database)
        let snapshot = try await repository.snapshot(meetingID: meeting.id)
        let entry = try await enqueue(repository, snapshot)
        try await repository.cancel(id: entry.id)
        do {
            try await repository.recordReceipt(id: entry.id, manifest: entry.manifest, receipt: Data("receipt".utf8))
            XCTFail("Cancelled is not a receipt")
        } catch MeetingCopyOutbox.Failure.invalid {}
        try await repository.retry(id: entry.id)
        do {
            try await repository.recordReceipt(id: entry.id, manifest: Data("changed".utf8), receipt: Data("receipt".utf8))
            XCTFail("Manifest mismatch")
        } catch MeetingCopyOutbox.Failure.invalid {}
        try await repository.recordReceipt(id: entry.id, manifest: entry.manifest, receipt: Data("receipt".utf8))
        let saved = try await repository.entry(id: entry.id)
        XCTAssertEqual(saved.state, "done")
        let synced = try await MeetingRepository(database).fetch(id: meeting.id)
        XCTAssertNotNil(synced?.syncedToMacAt)
        XCTAssertNil(synced?.audioVerifiedOnMacAt)
        do {
            try await repository.recordReceipt(id: entry.id, manifest: entry.manifest, receipt: Data("receipt".utf8))
            XCTFail("Duplicate receipt")
        } catch MeetingCopyOutbox.Failure.invalid {}
    }

    func testQueueCapacityIsAtomicAndDoesNotEvictReceipts() async throws {
        let database = try AppDatabase.inMemory()
        let repository = MeetingCopyOutbox(database)
        for _ in 0..<MeetingCopyOutbox.maximumEntries {
            let meeting = Self.meeting()
            try await MeetingRepository(database).insert(meeting)
            _ = try await enqueue(repository, repository.snapshot(meetingID: meeting.id))
        }
        let extra = Self.meeting()
        try await MeetingRepository(database).insert(extra)
        do {
            _ = try await enqueue(repository, repository.snapshot(meetingID: extra.id))
            XCTFail("Unbounded queue")
        } catch MeetingCopyOutbox.Failure.capacity {}
        let entries = try await repository.entries()
        XCTAssertEqual(entries.count, MeetingCopyOutbox.maximumEntries)
        XCTAssertTrue(entries.allSatisfy { $0.state == "queued" })
    }

    func testActivePublicationBlocksSnapshotAndEnqueueRaceWithoutAllocatingOutbox() async throws {
        for (table, state) in [
            ("recordingProcessingJob", "capturing"), ("recordingProcessingJob", "processing"),
            ("speakerAnalysisJob", "pending"), ("speakerAnalysisJob", "running"), ("speakerAnalysisJob", "rerun")
        ] {
            let database = try AppDatabase.inMemory()
            let meeting = Self.meeting()
            try await MeetingRepository(database).insert(meeting)
            let repository = MeetingCopyOutbox(database)
            let beforeProcessing = try await repository.snapshot(meetingID: meeting.id)
            try await database.writer.write { db in
                try db.execute(sql: "INSERT INTO \(table)(meetingId, state, updatedAt) VALUES (?, ?, ?)",
                               arguments: [meeting.id, state, Date()])
            }
            do { _ = try await repository.snapshot(meetingID: meeting.id); XCTFail("Active \(state)") }
            catch MeetingCopyOutbox.Failure.sourceProcessing {}
            // Models starting after the initial snapshot must also block the hash/enqueue race.
            do { _ = try await enqueue(repository, beforeProcessing); XCTFail("Raced \(state)") }
            catch MeetingCopyOutbox.Failure.sourceProcessing {}
            let entries = try await repository.entries()
            XCTAssertTrue(entries.isEmpty)
        }
    }

    func testTerminalRetryStatesAndFailedSpeakerAnalysisCanExportCurrentTranscript() async throws {
        for state in ["needsRetry", "interrupted", "complete"] {
            let database = try AppDatabase.inMemory()
            let meeting = Self.meeting()
            try await MeetingRepository(database).insert(meeting)
            try await database.writer.write { db in
                try db.execute(sql: "INSERT INTO recordingProcessingJob(meetingId, state, updatedAt) VALUES (?, ?, ?)",
                               arguments: [meeting.id, state, Date()])
                try db.execute(sql: "INSERT INTO speakerAnalysisJob(meetingId, state, updatedAt) VALUES (?, 'failed', ?)",
                               arguments: [meeting.id, Date()])
            }
            let repository = MeetingCopyOutbox(database)
            let snapshot = try await repository.snapshot(meetingID: meeting.id)
            let entry = try await enqueue(repository, snapshot)
            XCTAssertEqual(entry.state, "queued")
        }
    }

    func testProcessingStartedAfterEnqueuePausesPendingAttemptWithoutReplacingSnapshot() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Self.meeting()
        try await MeetingRepository(database).insert(meeting)
        let repository = MeetingCopyOutbox(database)
        let entry = try await enqueue(repository, repository.snapshot(meetingID: meeting.id))
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO recordingProcessingJob(meetingId, state, updatedAt) VALUES (?, 'processing', ?)",
                           arguments: [meeting.id, Date()])
        }
        do { try await repository.assertPending(id: entry.id); XCTFail("Publishing source") }
        catch MeetingCopyOutbox.Failure.sourceProcessing {}
        let saved = try await repository.entry(id: entry.id)
        XCTAssertEqual(saved.manifest, entry.manifest)
        XCTAssertEqual(saved.state, "queued")
    }

    private func enqueue(_ repository: MeetingCopyOutbox, _ snapshot: MeetingCopyOutbox.Snapshot) async throws -> MeetingCopyOutbox.Entry {
        try await repository.enqueue(snapshot: snapshot, peerKey: Data(repeating: 1, count: 32),
                                     manifest: Data("manifest".utf8), transcript: Data("transcript".utf8),
                                     sourceIdentity: Data("identity".utf8))
    }

    private static func meeting() -> Meeting {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Meeting(title: "Frozen", startedAt: now, durationMs: 10, audioFileName: "test.m4a",
                       audioSHA256: String(repeating: "a", count: 64), audioByteCount: 10,
                       state: .recorded, createdAt: now, updatedAt: now, originDeviceId: "qa")
    }
}
