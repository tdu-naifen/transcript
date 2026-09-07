import Foundation
import GRDB
import XCTest
@testable import TranscriptCore

final class MeetingCopyOutboxTests: XCTestCase {
    func testLegacyExportRequiresConsentAndDeterministicallyChangesOnlyCopyIDs() throws {
        let snapshot = Self.legacySnapshot()
        let fingerprint = try MeetingCopyOutbox.sourceFingerprint(snapshot)
        XCTAssertEqual(try MeetingCopyOutbox.legacyIdentifierCount(in: snapshot), 1)
        XCTAssertThrowsError(try MeetingCopyOutbox.copyIdentifiers(in: snapshot)) {
            guard case MeetingCopyOutbox.Failure.legacyConsentRequired = $0 else { return XCTFail("Consent required") }
        }
        let ids = try MeetingCopyOutbox.copyIdentifiers(in: snapshot, allowingLegacy: true)
        XCTAssertEqual(ids, ["bdacc7d4-249b-8729-bcf2-1a5f7cd8b1cd"], "Versioned projection recipe must not drift")
        XCTAssertEqual(ids, try MeetingCopyOutbox.copyIdentifiers(in: snapshot, allowingLegacy: true))
        XCTAssertEqual(ids.first?.count, 36)
        XCTAssertEqual(ids.first, ids.first.flatMap { UUID(uuidString: $0) }?.uuidString.lowercased())
        XCTAssertNotEqual(ids.first, snapshot.utterances.first?.id)
        XCTAssertEqual(try MeetingCopyOutbox.sourceFingerprint(snapshot), fingerprint)
        XCTAssertEqual(snapshot.utterances.first?.text.utf8.count, 85)
        XCTAssertEqual(snapshot.utterances.first?.endMs, 9100)
        XCTAssertEqual(snapshot.meeting.audioByteCount, 38_728)
    }

    func testLegacyProjectionRejectsUnknownGrammarWrongProvenanceAndCollisions() throws {
        let snapshot = Self.legacySnapshot()
        let item = try XCTUnwrap(snapshot.utterances.first)
        let prefix = "\(snapshot.meeting.id)-apple-22222222-2222-4222-8222-222222222222-"
        for badID in [prefix + "00", prefix + "-0", prefix + "1", prefix + "0-extra",
                      "33333333-3333-4333-8333-333333333333-apple-22222222-2222-4222-8222-222222222222-0",
                      "\(snapshot.meeting.id)-apple-00000000-0000-0000-0000-000000000000-0",
                      "\(snapshot.meeting.id)-apple-0", "unknown-invalid-id"] {
            var changed = item
            changed.id = badID
            XCTAssertThrowsError(try MeetingCopyOutbox.copyIdentifiers(
                in: .init(meeting: snapshot.meeting, utterances: [changed]), allowingLegacy: true
            ))
        }
        var wrongEngine = item
        wrongEngine.engine = .nemotron
        XCTAssertThrowsError(try MeetingCopyOutbox.legacyIdentifierCount(
            in: .init(meeting: snapshot.meeting, utterances: [wrongEngine])
        ))
        var collision = item
        collision.id = try XCTUnwrap(MeetingCopyOutbox.copyIdentifiers(in: snapshot, allowingLegacy: true).first)
        XCTAssertThrowsError(try MeetingCopyOutbox.copyIdentifiers(
            in: .init(meeting: snapshot.meeting, utterances: [item, collision]), allowingLegacy: true
        )) {
            guard case MeetingCopyOutbox.Failure.transcriptIdentity = $0 else { return XCTFail("Collision must fail") }
        }
    }

    func testCanonicalIDsRemainUnchangedAndRawFingerprintDetectsSourceEdits() throws {
        let original = Self.legacySnapshot()
        var item = try XCTUnwrap(original.utterances.first)
        item.id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let normal = MeetingCopyOutbox.Snapshot(meeting: original.meeting, utterances: [item])
        XCTAssertEqual(try MeetingCopyOutbox.legacyIdentifierCount(in: normal), 0)
        XCTAssertEqual(try MeetingCopyOutbox.copyIdentifiers(in: normal), [item.id.lowercased()])
        let before = try MeetingCopyOutbox.sourceFingerprint(normal)
        item.text += " edited"
        item.revision += 1
        let edited = MeetingCopyOutbox.Snapshot(meeting: original.meeting, utterances: [item])
        XCTAssertNotEqual(try MeetingCopyOutbox.sourceFingerprint(edited), before)
    }

    func testDurableSnapshotRetainsLegacySourceIdentityAfterProjection() async throws {
        let database = try AppDatabase.inMemory()
        let source = Self.legacySnapshot()
        try await MeetingRepository(database).insert(source.meeting)
        try await UtteranceRepository(database).append(source.utterances)
        let repository = MeetingCopyOutbox(database)
        let raw = try await repository.snapshot(meetingID: source.meeting.id)
        _ = try MeetingCopyOutbox.copyIdentifiers(in: raw, allowingLegacy: true)
        let entry = try await enqueue(repository, raw)
        let stored = try JSONDecoder().decode(MeetingCopyOutbox.Snapshot.self, from: entry.snapshot)
        XCTAssertEqual(stored, raw)
        XCTAssertEqual(stored.utterances.first?.id, source.utterances.first?.id)
        XCTAssertEqual(try MeetingCopyOutbox.sourceFingerprint(stored), try MeetingCopyOutbox.sourceFingerprint(raw))
        let current = try await repository.validate(id: entry.id)
        XCTAssertEqual(current, raw)
    }

    private static func legacySnapshot() -> MeetingCopyOutbox.Snapshot {
        let id = "11111111-1111-4111-8111-111111111111"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = Meeting(id: id, title: "Synthetic legacy copy", startedAt: now, durationMs: 9100,
            audioFileName: "\(id).m4a", audioSHA256: String(repeating: "a", count: 64),
            audioByteCount: 38_728, state: .recorded, createdAt: now, updatedAt: now, originDeviceId: "test")
        let item = Utterance(id: "\(id)-apple-22222222-2222-4222-8222-222222222222-0",
            meetingId: id, startMs: 0, endMs: 9100, text: String(repeating: "x", count: 85),
            engine: .appleSpeech, createdAt: now, updatedAt: now, originDeviceId: "test")
        return .init(meeting: meeting, utterances: [item])
    }

    func testLegacyProvenanceIsDiagnosedBeforeEnumDecodingAndNeverRewritten() async throws {
        for (engine, revision) in [("legacyEngine", 1), ("appleSpeech", 0), ("nemotron", 2147483648)] {
            let database = try AppDatabase.inMemory()
            let meeting = Self.meeting()
            try await MeetingRepository(database).insert(meeting)
            let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 10,
                                      text: "Retained", originDeviceId: "qa")
            try await database.writer.write { db in
                try utterance.insert(db)
                try db.execute(sql: "UPDATE utterance SET engine = ?, revision = ? WHERE id = ?",
                               arguments: [engine, revision, utterance.id])
            }
            let repository = MeetingCopyOutbox(database)
            do { _ = try await repository.snapshot(meetingID: meeting.id); XCTFail("Unsupported provenance") }
            catch MeetingCopyOutbox.Failure.transcriptProvenance {}
            let raw = try await database.reader.read {
                try Row.fetchOne($0, sql: "SELECT engine, revision, text FROM utterance WHERE id = ?", arguments: [utterance.id])
            }
            XCTAssertEqual(raw?["engine"] as String?, engine)
            XCTAssertEqual(raw?["revision"] as Int?, revision)
            XCTAssertEqual(raw?["text"] as String?, "Retained")
            let entries = try await repository.entries()
            XCTAssertTrue(entries.isEmpty)
        }
    }

    func testReceiptCommitFailureDoesNotMarkMeetingSyncedOrDropFrozenExport() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Self.meeting()
        try await MeetingRepository(database).insert(meeting)
        let repository = MeetingCopyOutbox(database)
        let entry = try await enqueue(repository, repository.snapshot(meetingID: meeting.id))
        try await database.writer.write {
            try $0.execute(sql: """
                CREATE TRIGGER fail_synced BEFORE UPDATE OF syncedToMacAt ON meeting
                BEGIN SELECT RAISE(ABORT, 'injected final commit failure'); END;
                """)
        }
        do {
            try await repository.recordReceipt(id: entry.id, manifest: entry.manifest, receipt: Data("receipt".utf8))
            XCTFail("Atomic receipt save must fail")
        } catch is DatabaseError {}
        let failed = try await repository.entry(id: entry.id)
        XCTAssertEqual(failed.state, "queued")
        XCTAssertNil(failed.receipt)
        XCTAssertEqual(failed.manifest, entry.manifest)
        let unchanged = try await MeetingRepository(database).fetch(id: meeting.id)
        XCTAssertEqual(unchanged, meeting)
    }

    func testLegacyTranscriptDurationBoundaryIsRejectedWithoutChangingPublishedRows() async throws {
        for (start, end, accepted) in [(0, 8999, true), (0, 9000, true), (0, 9001, false),
                                       (-1, 9000, false), (9000, 8999, false)] {
            let database = try AppDatabase.inMemory()
            var meeting = Self.meeting()
            meeting.durationMs = 9000
            meeting.audioByteCount = 39_000
            let original = meeting
            try await MeetingRepository(database).insert(original)
            let utterance = Utterance(meetingId: original.id, startMs: start, endMs: end,
                                      text: "Published legacy transcript", createdAt: original.createdAt,
                                      updatedAt: original.updatedAt, originDeviceId: "qa")
            try await database.writer.write { try utterance.insert($0) }
            let repository = MeetingCopyOutbox(database)
            do {
                let snapshot = try await repository.snapshot(meetingID: original.id)
                XCTAssertTrue(accepted, "\(start)...\(end)")
                XCTAssertEqual(snapshot.utterances, [utterance])
                _ = try await enqueue(repository, snapshot)
            } catch MeetingCopyOutbox.Failure.transcriptTiming {
                XCTAssertFalse(accepted, "\(start)...\(end)")
            }
            let entries = try await repository.entries()
            XCTAssertEqual(entries.count, accepted ? 1 : 0)
            let unchanged = try await MeetingRepository(database).fetch(id: original.id)
            let rows = try await database.reader.read { try Utterance.fetchAll($0) }
            XCTAssertEqual(unchanged, original)
            XCTAssertEqual(rows, [utterance], "Do not clear text, clamp times, or rewrite the source")
        }
    }

    func testEnqueueStorageFailureRollsBackWithoutCreatingCopyOrReceipt() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Self.meeting()
        try await MeetingRepository(database).insert(meeting)
        let repository = MeetingCopyOutbox(database)
        let snapshot = try await repository.snapshot(meetingID: meeting.id)
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_copy_insert BEFORE INSERT ON meetingCopyOutbox
                BEGIN SELECT RAISE(ABORT, 'injected queue save failure'); END;
                """)
        }
        do { _ = try await enqueue(repository, snapshot); XCTFail("Save must fail") }
        catch is DatabaseError {}
        let entries = try await repository.entries()
        XCTAssertTrue(entries.isEmpty)
        let unchanged = try await MeetingRepository(database).fetch(id: meeting.id)
        XCTAssertEqual(unchanged, meeting)
    }

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
