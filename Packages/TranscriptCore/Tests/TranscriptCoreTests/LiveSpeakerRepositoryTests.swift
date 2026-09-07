import Foundation
import GRDB
import XCTest
@testable import TranscriptCore

@MainActor
final class LiveSpeakerRepositoryTests: XCTestCase {
    private func fixture() async throws -> (AppDatabase, Meeting, LiveSpeakerRepository, LiveSpeakerIdentity) {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Live", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let repo = LiveSpeakerRepository(database: db, meetingID: meeting.id, epoch: UUID().uuidString,
                                         deviceID: "test", authorization: .init())
        try await repo.begin(generation: 0)
        return (db, meeting, repo, .init(id: UUID().uuidString, ordinal: 0))
    }

    private func voice(_ identity: LiveSpeakerIdentity, frames: Int = 32_000, dimension: Int = 192) -> LiveSpeakerVoice {
        .init(identityID: identity.id, embedding: [1] + Array(repeating: 0, count: dimension - 1), cleanFrameCount: frames)
    }
    private func span(_ identity: LiveSpeakerIdentity?, start: Int = 0, end: Int = 2_000, unknown: Bool = false) -> LiveSpeakerSpan {
        .init(startTick: Int64(start) * 9_424, endTick: Int64(end) * 9_424, identityID: identity?.id, unknown: unknown)
    }
    private func append(_ db: AppDatabase, _ meeting: Meeting, end: Int = 1_000) async throws -> Utterance {
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: end, text: "Preserved text", originDeviceId: "test")
        try await UtteranceRepository(db).append([utterance])
        return utterance
    }

    func testQualifiedEarlyCAMAndLateASRShareDurableProjectionAndV10Proof() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        let early = try await append(db, meeting)
        _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
        try await repo.reconcile(generation: 0)
        let late = try await append(db, meeting, end: 1_500)
        try await repo.reconcile(generation: 0)
        let rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[0].speakerId)
        XCTAssertEqual(rows[0].speakerId, rows[1].speakerId)
        XCTAssertEqual(Set(rows.map(\.text)), Set([early.text, late.text]))
        let proof = try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM speakerAnalysisAutomaticAssignment") }
        XCTAssertEqual(proof, 2)
        let bank = try await SpeakerRepository(db).embeddings(forSpeaker: try XCTUnwrap(rows[0].speakerId))
        XCTAssertEqual(bank.map(\.dimension), [192])
        XCTAssertEqual(bank.map(\.modelIdentifier), ["CAM-test"])
    }

    func testUnboundUnknownOverlapAndIncompleteCoverageDoNotAssign() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        _ = try await append(db, meeting, end: 3_000)
        _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [], modelIdentifier: "CAM-test")
        try await repo.reconcile(generation: 0)
        var rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertNil(rows[0].speakerId)
        _ = try await repo.publish(generation: 0, identities: [], spans: [span(nil, start: 2_000, end: 4_000, unknown: true)], voices: [voice(identity)], modelIdentifier: "CAM-test")
        try await repo.reconcile(generation: 0)
        rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertNil(rows[0].speakerId)
        XCTAssertEqual(rows[0].revision, 1)
    }

    func testManualClearSameIDAndGlobalRenameAreNeverOverwritten() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        let row = try await append(db, meeting)
        _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
        try await repo.reconcile(generation: 0)
        let assigned = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        let speaker = try XCTUnwrap(assigned[0].speakerId)
        try await UtteranceRepository(db).assignSpeaker(utteranceId: row.id, speakerId: speaker, deviceId: "manual")
        try await SpeakerRepository(db).rename(id: speaker, displayName: "My chosen name", deviceId: "manual")
        try await repo.reconcile(generation: 0)
        var after = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertEqual(after[0].speakerId, speaker)
        try await UtteranceRepository(db).assignSpeaker(utteranceId: row.id, speakerId: nil, deviceId: "manual")
        try await repo.reconcile(generation: 0)
        after = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertNil(after[0].speakerId)
        let named = try await SpeakerRepository(db).fetch(id: speaker)
        XCTAssertEqual(named?.displayName, "My chosen name")
    }

    func testCurrentGlobalBankIsMatchedTransactionallyAndAmbiguousTieAbstains() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        let known = Speaker(displayName: "Known", anonymousName: "Animal", colorIndex: 0, originDeviceId: "manual")
        let initialVector = voice(identity).embedding
        try await db.writer.write {
            try known.insert($0)
            try SpeakerEmbedding(speakerId: known.id, floats: initialVector, originDeviceId: "test", modelIdentifier: "CAM-test").insert($0)
        }
        _ = try await append(db, meeting)
        _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
        try await repo.reconcile(generation: 0)
        let rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows[0].speakerId, known.id)
        let tied = Speaker(anonymousName: "Other", colorIndex: 1, originDeviceId: "manual")
        let vector = voice(identity).embedding
        try await db.writer.write {
            try tied.insert($0)
            try SpeakerEmbedding(speakerId: tied.id, floats: vector, originDeviceId: "test", modelIdentifier: "CAM-test").insert($0)
        }
        let second = LiveSpeakerIdentity(id: UUID().uuidString, ordinal: 1)
        let bound = try await repo.publish(generation: 0, identities: [second], spans: [], voices: [voice(second)], modelIdentifier: "CAM-test")
        XCTAssertFalse(bound.bound.contains(second.id))
        let count = try await db.reader.read { try Speaker.fetchCount($0) }
        XCTAssertEqual(count, 2)
    }

    func testCancellationNewEpochDeletionAndOfflineOwnershipFenceAllWrites() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        repo.authorization.setActive(false)
        do {
            _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
            XCTFail("Revoked generation")
        } catch is CancellationError {}
        repo.authorization.setActive(true)
        let replacement = LiveSpeakerRepository(database: db, meetingID: meeting.id, epoch: UUID().uuidString,
                                                deviceID: "new", authorization: .init())
        try await replacement.begin(generation: 0)
        do {
            _ = try await repo.publish(generation: 2, identities: [identity], spans: [], voices: [], modelIdentifier: "CAM-test")
            XCTFail("Replaced epoch")
        } catch VoiceprintBindingError.staleExpectation {}
        try await SpeakerAnalysisRepository(db).enqueue(meetingID: meeting.id)
        do { try await replacement.reconcile(generation: 0); XCTFail("Offline owns identities") }
        catch VoiceprintBindingError.staleExpectation {}
        try await db.writer.write { _ = try Meeting.deleteOne($0, key: meeting.id) }
        do { try await replacement.begin(generation: 0); XCTFail("Deleted meeting") }
        catch VoiceprintBindingError.staleExpectation {}
        let count = try await db.reader.read { try Speaker.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testWrongVectorSpaceShortEvidenceAndInjectedFailureAllocateNothing() async throws {
        let (db, _, repo, identity) = try await fixture()
        for invalid in [voice(identity, frames: 31_999), voice(identity, dimension: 256)] {
            do {
                _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [invalid], modelIdentifier: "CAM-test")
                XCTFail("Invalid evidence")
            } catch VoiceprintBindingError.invalidEmbedding {}
        }
        try await db.writer.write { try $0.execute(sql: """
            CREATE TRIGGER live_fail BEFORE INSERT ON speaker BEGIN SELECT RAISE(ABORT, 'injected'); END;
            """) }
        do {
            _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
            XCTFail("Injected failure")
        } catch {}
        let counts = try await db.reader.read { db in
            try ["liveSpeakerIdentity", "liveSpeakerSpan", "speaker", "speakerEmbedding"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    func testPagedReconciliationDoesNotStopAtFirst128Rows() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        let rows = (0..<270).map { index in
            Utterance(meetingId: meeting.id, startMs: 0, endMs: 1_000, text: "Line \(index)", originDeviceId: "test")
        }
        try await UtteranceRepository(db).append(rows)
        _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
        let more = try await repo.reconcilePage(generation: 0)
        XCTAssertTrue(more)
        try await repo.reconcile(generation: 0)
        let result = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertEqual(result.compactMap(\.speakerId).count, 270)
    }

    func testLateFinalAfterSealUsesOnlyAcceptedEvidenceWithoutNewTemplates() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        _ = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
        repo.authorization.close()
        try await db.writer.write {
            try $0.execute(sql: "UPDATE meeting SET state = 'recorded' WHERE id = ?", arguments: [meeting.id])
        }
        _ = try await append(db, meeting)
        try await repo.reconcile(generation: nil)
        let rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertNotNil(rows[0].speakerId)
        let count = try await db.reader.read { try SpeakerEmbedding.fetchCount($0) }
        XCTAssertEqual(count, 1)
    }

    func testRevocationWhileWaitingForDatabaseCannotCommitAnyIdentity() async throws {
        let (db, _, repo, identity) = try await fixture()
        let entered = expectation(description: "Writer held")
        let release = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await db.writer.write { _ in entered.fulfill(); release.wait() }
        }
        await fulfillment(of: [entered], timeout: 2)
        let spans = [span(identity)]
        let voices = [voice(identity)]
        let publication = Task {
            try await repo.publish(generation: 0, identities: [identity], spans: spans, voices: voices, modelIdentifier: "CAM-test")
        }
        repo.authorization.close()
        release.signal()
        try await blocker.value
        do { _ = try await publication.value; XCTFail("Revoked while waiting") }
        catch is CancellationError {}
        let count = try await db.reader.read { try Speaker.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testOversizedGlobalBankAbstainsWithoutLoadingOrExtendingIt() async throws {
        let (db, meeting, repo, identity) = try await fixture()
        try await db.writer.write { db in
            for index in 0...LiveSpeakerLimits.bankEntries {
                try Speaker(anonymousName: "Existing \(index)", originDeviceId: "fixture").insert(db)
            }
        }
        _ = try await append(db, meeting)
        let result = try await repo.publish(generation: 0, identities: [identity], spans: [span(identity)], voices: [voice(identity)], modelIdentifier: "CAM-test")
        XCTAssertTrue(result.capacityLimited)
        XCTAssertTrue(result.bound.isEmpty)
        try await repo.reconcile(generation: 0)
        let rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        let templates = try await db.reader.read { try SpeakerEmbedding.fetchCount($0) }
        XCTAssertNil(rows[0].speakerId)
        XCTAssertEqual(templates, 0)
    }

    func testV10UpgradePreservesAutomaticProofAndDoesNotBackfillLiveIdentity() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v10_local_speaker_analysis_assignment_provenance")
        let meeting = Meeting(title: "Existing", startedAt: Date(), state: .recorded, originDeviceId: "legacy")
        let speaker = Speaker(anonymousName: "Existing person", originDeviceId: "legacy")
        var original = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1_000, text: "Existing", originDeviceId: "legacy")
        original.speakerId = speaker.id
        original.revision = 2
        let row = original
        try await queue.write {
            try meeting.insert($0)
            try speaker.insert($0)
            try row.insert($0)
            try $0.execute(sql: """
                INSERT INTO speakerAnalysisAutomaticAssignment(utteranceId, speakerId, utteranceRevision) VALUES (?, ?, 2)
                """, arguments: [row.id, speaker.id])
        }
        let storedBeforeUpgrade = try await queue.read { try Utterance.fetchAll($0) }
        let upgraded = try AppDatabase(queue)
        let rows = try await UtteranceRepository(upgraded).fetch(meetingId: meeting.id)
        let counts = try await upgraded.reader.read { db in
            try ["speakerAnalysisAutomaticAssignment", "liveSpeakerSession", "liveSpeakerIdentity", "liveSpeakerSpan", "liveSpeakerChecked"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(rows, storedBeforeUpgrade)
        XCTAssertEqual(counts, [1, 0, 0, 0, 0])
    }
}
