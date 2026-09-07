import AVFoundation
import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacMeetingCopyInboxTests: XCTestCase {
    private typealias Inbox = MacMeetingCopyInbox

    func testCaseInsensitiveCollisionLookupsUseIndexesRatherThanScanningTranscripts() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        _ = try Inbox(context: store.context)
        let plans = try await store.context.database.reader.read { db in
            try ["utterance", "meeting"].map { table in
                let rows = try Row.fetchAll(
                    db, sql: "EXPLAIN QUERY PLAN SELECT EXISTS(SELECT 1 FROM \(table) WHERE lower(id) = ?)",
                    arguments: [UUID().uuidString.lowercased()]
                )
                return rows.map { $0["detail"] as String }.joined(separator: "\n")
            }
        }
        XCTAssertTrue(plans[0].contains("SEARCH utterance USING")
                      && plans[0].contains("INDEX mac_copy_utterance_casefold"), plans[0])
        XCTAssertTrue(plans[1].contains("SEARCH meeting USING")
                      && plans[1].contains("INDEX mac_copy_meeting_casefold"), plans[1])
    }

    func testRoundtripImportsAudioAndTextAndReplaysDurableReceiptAfterDeletion() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        let reserved = try await inbox.reserve(fixture.offer)
        XCTAssertNil(reserved.receipt)
        XCTAssertEqual(reserved.audio.offset, 0)
        await expect(.incomplete) { _ = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode) }
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        let audioOnly = try await inbox.status(fixture.offer)
        XCTAssertNil(audioOnly.receipt)
        XCTAssertEqual(audioOnly.audio.sha256, hash(audio))
        try await upload(fixture.text, .transcript, to: inbox, offer: fixture.offer)
        let completeBytes = try await inbox.status(fixture.offer)
        XCTAssertNil(completeBytes.receipt)
        let receipt = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode)

        let reopened = try MacLibraryStore(directory: root)
        let items = try await reopened.load()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.meeting.id, fixture.offer.manifest.meetingID)
        XCTAssertEqual(item.meeting.originDeviceId, "iphone-test")
        XCTAssertEqual(item.utterances.map(\.text), ["Hello from the iPhone"])
        XCTAssertEqual(item.utterances.first?.id, fixture.segmentID)
        XCTAssertEqual(item.utterances.first?.originDeviceId, "iphone-test")
        XCTAssertEqual(item.utterances.first?.revision, 3)
        XCTAssertNil(item.utterances.first?.speakerId)
        XCTAssertTrue(item.speakers.isEmpty)
        let rag = try MacAnalysisEvidence.prepare(mode: .rag, question: "iPhone", meetingID: item.id, items: items)
        let citation = try XCTUnwrap(rag.evidence.first)
        XCTAssertEqual(citation.meetingID, fixture.offer.manifest.meetingID)
        XCTAssertEqual(citation.utteranceID, fixture.segmentID)
        XCTAssertEqual(citation.sourceText, "Hello from the iPhone")
        XCTAssertEqual(citation.sourceRevision, 3)
        let audioURL = try reopened.audioFiles.url(forFileName: XCTUnwrap(item.meeting.audioFileName))
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        let restarted = try Inbox(context: reopened.context)
        let replay = try await restarted.reserve(fixture.offer)
        XCTAssertEqual(replay.receipt, receipt)
        let finalizedAgain = try await restarted.finalize(fixture.offer) { _ in
            XCTFail("Committed receipt replay must not decode or import again")
            throw Inbox.Failure.invalidTranscript
        }
        XCTAssertEqual(finalizedAgain, receipt)

        try await reopened.context.database.writer.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [fixture.offer.manifest.meetingID])
        }
        try FileManager.default.removeItem(at: audioURL)
        let afterDeletion = try await restarted.finalize(fixture.offer, decodeTranscript: Self.decode)
        XCTAssertEqual(afterDeletion, receipt)
        let deletedItems = try await reopened.load()
        XCTAssertTrue(deletedItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        await expect(.meetingExists) {
            _ = try await restarted.reserve(self.replacing(fixture.offer, operation: UUID()))
        }
    }

    func testPartialRestartVerifiesPrefixAndDuplicateChunkIsIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        let first = Data(audio.prefix(127))
        let prefix = try await inbox.append(first, asset: .audio, offset: 0, sha256: hash(first), offer: fixture.offer)
        XCTAssertEqual(prefix, Inbox.Prefix(offset: 127, sha256: hash(first)))
        let duplicatePrefix = try await inbox.append(first, asset: .audio, offset: 0, sha256: hash(first), offer: fixture.offer)
        XCTAssertEqual(duplicatePrefix, prefix)
        let reopened = try MacLibraryStore(directory: root)
        let restarted = try Inbox(context: reopened.context)
        let resumed = try await restarted.reserve(fixture.offer)
        XCTAssertEqual(resumed.audio, Inbox.Prefix(offset: 127, sha256: hash(first)))
        XCTAssertNil(resumed.receipt)
        try await upload(audio, .audio, to: restarted, offer: fixture.offer, from: 127)
        try await upload(fixture.text, .transcript, to: restarted, offer: fixture.offer)
        _ = try await restarted.finalize(fixture.offer, decodeTranscript: Self.decode)
        let items = try await reopened.load()
        XCTAssertEqual(items.count, 1)
    }

    func testManyChunkStreamingPrefixesSurviveDuplicatesRestartAndAnotherWriter() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        var inbox = try Inbox(context: store.context)
        let audio = Data((0..<(512 * Inbox.chunkLimit + 37)).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        let textPrefix = try await inbox.append(fixture.text, asset: .transcript, offset: 0,
                                                sha256: hash(fixture.text), offer: fixture.offer)
        XCTAssertEqual(textPrefix, Inbox.Prefix(offset: fixture.text.count, sha256: hash(fixture.text)))
        let first = Data(audio.prefix(Inbox.chunkLimit))
        var expectedHasher = IncrementalSHA256()
        var offset = 0
        var chunkIndex = 0
        while offset < audio.count {
            let end = min(offset + Inbox.chunkLimit, audio.count)
            let bytes = audio.subdata(in: offset..<end)
            if chunkIndex == 128 {
                inbox = try Inbox(context: store.context)
                let replay = try await inbox.append(first, asset: .audio, offset: 0,
                                                     sha256: hash(first), offer: fixture.offer)
                XCTAssertEqual(replay, Inbox.Prefix(offset: offset, sha256: hash(Data(audio.prefix(offset)))))
            }
            let writer = chunkIndex == 256 ? try Inbox(context: store.context) : inbox
            let acknowledged = try await writer.append(bytes, asset: .audio, offset: offset,
                                                        sha256: hash(bytes), offer: fixture.offer)
            expectedHasher.update(bytes)
            var snapshot = expectedHasher
            XCTAssertEqual(acknowledged, Inbox.Prefix(offset: end, sha256: snapshot.finalize()))
            if chunkIndex.isMultiple(of: 32) {
                let duplicate = try await writer.append(first, asset: .audio, offset: 0,
                                                         sha256: hash(first), offer: fixture.offer)
                XCTAssertEqual(duplicate, acknowledged)
                let textReplay = try await inbox.append(fixture.text, asset: .transcript, offset: 0,
                                                        sha256: hash(fixture.text), offer: fixture.offer)
                XCTAssertEqual(textReplay, textPrefix)
            }
            offset = end
            chunkIndex += 1
        }
        let status = try await inbox.status(fixture.offer)
        XCTAssertEqual(status.audio, Inbox.Prefix(offset: audio.count, sha256: hash(audio)))
        XCTAssertEqual(status.transcript, textPrefix)
        XCTAssertNil(status.receipt)
        try await inbox.cancel(fixture.offer)
    }

    func testFailedChunkCommitDoesNotAdvanceAcknowledgedHash() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = Data([1, 2, 3, 4])
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        let first = Data([1, 2])
        let initial = try await inbox.append(first, asset: .audio, offset: 0,
                                             sha256: hash(first), offer: fixture.offer)
        try await store.context.database.writer.write { db in
            try db.execute(sql: """
                CREATE TABLE reject_copy_reference (
                    meetingID TEXT REFERENCES meeting(id) DEFERRABLE INITIALLY DEFERRED
                );
                CREATE TRIGGER reject_chunk_commit AFTER UPDATE OF audioOffset ON mac_copy_inbox
                BEGIN INSERT INTO reject_copy_reference VALUES ('missing'); END;
                """)
        }
        do {
            let rejected = Data([9, 9])
            _ = try await inbox.append(rejected, asset: .audio, offset: 2,
                                        sha256: hash(rejected), offer: fixture.offer)
            XCTFail("The deferred foreign key must reject COMMIT after the chunk write")
        } catch let error as DatabaseError {
            XCTAssertTrue(error.description.contains("FOREIGN KEY"))
        }
        let duplicate = try await inbox.append(first, asset: .audio, offset: 0,
                                                sha256: hash(first), offer: fixture.offer)
        XCTAssertEqual(duplicate, initial)
        try await store.context.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER reject_chunk_commit")
        }
        let final = Data([3, 4])
        let acknowledged = try await inbox.append(final, asset: .audio, offset: 2,
                                                   sha256: hash(final), offer: fixture.offer)
        XCTAssertEqual(acknowledged, Inbox.Prefix(offset: audio.count, sha256: hash(audio)))
    }

    func testOffsetMismatchRecoveryRehashesPersistedChunks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let fixture = try makeOffer(audio: Data([1, 2, 3]))
        _ = try await inbox.reserve(fixture.offer)
        _ = try await inbox.append(Data([1]), asset: .audio, offset: 0,
                                    sha256: hash(Data([1])), offer: fixture.offer)
        let other = try Inbox(context: store.context)
        _ = try await other.append(Data([2]), asset: .audio, offset: 1,
                                    sha256: hash(Data([2])), offer: fixture.offer)
        try await store.context.database.writer.write { db in
            try db.execute(sql: "UPDATE mac_copy_chunks SET digest = 'corrupt' WHERE asset = 'audio' AND offset = 0")
        }
        await expect(.digestMismatch) {
            _ = try await inbox.append(Data([3]), asset: .audio, offset: 2,
                                        sha256: self.hash(Data([3])), offer: fixture.offer)
        }
    }

    func testBindingsOffsetsAndChunkDigestsRejectMismatches() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let fixture = try makeOffer(audio: Data(repeating: 7, count: 2048))
        _ = try await inbox.reserve(fixture.offer)
        await expect(.unauthorized) {
            _ = try await inbox.status(self.replacing(fixture.offer, peer: Data(repeating: 2, count: 32)))
        }
        await expect(.unauthorized) {
            _ = try await inbox.status(self.replacing(fixture.offer, receiver: Data(repeating: 3, count: 32)))
        }
        await expect(.unauthorized) {
            _ = try await inbox.reserve(self.replacing(fixture.offer, peer: Data(repeating: 1, count: 31)))
        }
        await expect(.conflictingOperation) {
            _ = try await inbox.reserve(self.replacing(fixture.offer, snapshot: Data("changed snapshot".utf8)))
        }
        let changedMetadata = try makeOffer(audio: Data(repeating: 7, count: 2048),
                                           id: fixture.offer.manifest.meetingID, title: "Changed metadata")
        let rebound = replacing(changedMetadata.offer, operation: fixture.offer.operationID,
                                snapshot: fixture.offer.manifestSnapshot)
        await expect(.conflictingOperation) { _ = try await inbox.reserve(rebound) }
        await expect(.meetingExists) {
            _ = try await inbox.reserve(self.replacing(fixture.offer, operation: UUID()))
        }
        await expect(.wrongOffset) {
            _ = try await inbox.append(Data([7]), asset: .audio, offset: 1,
                                       sha256: self.hash(Data([7])), offer: fixture.offer)
        }
        await expect(.digestMismatch) {
            _ = try await inbox.append(Data([7]), asset: .audio, offset: 0,
                                       sha256: self.hash(Data([8])), offer: fixture.offer)
        }
        await expect(.invalidChunk) {
            let bytes = Data(repeating: 7, count: 769)
            _ = try await inbox.append(bytes, asset: .audio, offset: 0,
                                       sha256: self.hash(bytes), offer: fixture.offer)
        }
        _ = try await inbox.append(Data([7]), asset: .audio, offset: 0,
                                   sha256: hash(Data([7])), offer: fixture.offer)
        await expect(.wrongOffset) {
            _ = try await inbox.append(Data([8]), asset: .audio, offset: 0,
                                       sha256: self.hash(Data([8])), offer: fixture.offer)
        }
    }

    func testExistingAndDeletedMeetingCollisionsAreCaseInsensitive() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let id = UUID().uuidString
        let fixture = try makeOffer(audio: Data([1]), id: id.lowercased())
        let meeting = Meeting(id: id, title: "Existing", startedAt: Date(), originDeviceId: "mac")
        try await MeetingRepository(store.context.database).insert(meeting)
        await expect(.meetingExists) { _ = try await inbox.reserve(fixture.offer) }
        try await store.context.database.writer.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [id])
        }
        await expect(.meetingExists) { _ = try await inbox.reserve(fixture.offer) }
        let items = try await store.load()
        XCTAssertTrue(items.isEmpty)
    }

    func testInvalidAudioAndInvalidTranscriptNeverProduceReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = Data("not an m4a file".utf8)
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        try await upload(fixture.text, .transcript, to: inbox, offer: fixture.offer)
        await expect(.invalidTranscript) {
            _ = try await inbox.finalize(fixture.offer) { data in
                let transcript = try Self.decode(data)
                let segment = transcript.segments[0]
                let duplicate = Inbox.Segment(
                    id: segment.id.uppercased(), startMs: segment.startMs, endMs: segment.endMs,
                    text: segment.text, locale: segment.locale, revision: segment.revision, source: segment.source
                )
                return Inbox.Transcript(revision: transcript.revision, parentRevision: transcript.parentRevision,
                                        locale: transcript.locale, segments: [segment, duplicate])
            }
        }
        await expect(.invalidAudio) { _ = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode) }
        let status = try await inbox.status(fixture.offer)
        XCTAssertNil(status.receipt)
        let items = try await store.load()
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.audioFiles.directory.path).isEmpty)
        try await inbox.cancel(fixture.offer)
        try await inbox.cancel(fixture.offer)
        await expect(.cancelled) { _ = try await inbox.reserve(fixture.offer) }
    }

    func testFailedDatabaseCommitRecoversOwnedLandedFileWithoutEarlyReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        try await upload(fixture.text, .transcript, to: inbox, offer: fixture.offer)
        try await store.context.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_copy BEFORE INSERT ON utterance
                BEGIN SELECT RAISE(ABORT, 'test interrupted import'); END
                """)
        }
        do {
            _ = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode)
            XCTFail("Database failure must escape without a receipt")
        } catch let error as DatabaseError {
            XCTAssertTrue(error.description.contains("test interrupted import"))
        }
        let status = try await inbox.status(fixture.offer)
        XCTAssertNil(status.receipt)
        let items = try await store.load()
        XCTAssertTrue(items.isEmpty)
        let landed = try store.audioFiles.url(for: fixture.offer.manifest.meetingID.lowercased())
        XCTAssertEqual(try Data(contentsOf: landed), audio)
        try await store.context.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER reject_copy")
        }
        let restartedStore = try MacLibraryStore(directory: root)
        let restarted = try Inbox(context: restartedStore.context)
        _ = try await restarted.finalize(fixture.offer, decodeTranscript: Self.decode)
        let imported = try await restartedStore.load()
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.utterances.count, 1)
    }

    func testPartialMaterializationIsRebuiltFromDurableChunks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        try await upload(fixture.text, .transcript, to: inbox, offer: fixture.offer)
        let stage = root.appendingPathComponent("MacMeetingCopyInbox")
            .appendingPathComponent(fixture.offer.operationID.uuidString + ".m4a")
        try Data(audio.prefix(97)).write(to: stage)
        _ = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        let items = try await store.load()
        XCTAssertEqual(items.count, 1)
    }

    func testForeignDestinationAndSymbolicStageAreNeverOverwritten() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        try await upload(fixture.text, .transcript, to: inbox, offer: fixture.offer)
        let stage = root.appendingPathComponent("MacMeetingCopyInbox")
            .appendingPathComponent(fixture.offer.operationID.uuidString + ".m4a")
        let foreign = root.appendingPathComponent("foreign.m4a")
        try audio.write(to: foreign)
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: foreign)
        await expect(.unsafeFile) { _ = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode) }
        XCTAssertEqual(try Data(contentsOf: foreign), audio)
        try FileManager.default.removeItem(at: stage)
        let landed = try store.audioFiles.url(for: fixture.offer.manifest.meetingID.lowercased())
        try audio.write(to: landed)
        await expect(.meetingExists) { _ = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode) }
        XCTAssertEqual(try Data(contentsOf: landed), audio)
        let status = try await inbox.status(fixture.offer)
        XCTAssertNil(status.receipt)
    }

    func testCorruptDurablePrefixAndWrongFullAssetHashAreRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        var changedText = fixture.text
        changedText[0] ^= 1
        try await upload(changedText, .transcript, to: inbox, offer: fixture.offer)
        await expect(.digestMismatch) { _ = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode) }
        try await store.context.database.writer.write { db in
            try db.execute(sql: "UPDATE mac_copy_chunks SET digest = 'corrupt' WHERE asset = 'audio'")
        }
        let restarted = try Inbox(context: store.context)
        await expect(.digestMismatch) { _ = try await restarted.status(fixture.offer) }
    }

    func testReservationsAreBoundedAndCancellationReleasesActiveQuota() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        var offers: [Inbox.Offer] = []
        for _ in 0..<4 {
            let fixture = try makeOffer(audio: Data([1]))
            offers.append(fixture.offer)
            _ = try await inbox.reserve(fixture.offer)
        }
        let extra = try makeOffer(audio: Data([1]))
        await expect(.quotaExceeded) { _ = try await inbox.reserve(extra.offer) }
        try await inbox.cancel(offers[0])
        _ = try await inbox.reserve(extra.offer)
        let cancelled = offers[0]
        await expect(.cancelled) { _ = try await inbox.status(cancelled) }
        let durability = try await store.context.database.writer.writeWithoutTransaction { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous")
        }
        XCTAssertEqual(durability, 2)
    }

    func testEveryTransactionEnforcesFullDurabilityAfterWriterReconfigurationAndReopen() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let otherStore = try MacLibraryStore(directory: root)
        let otherInbox = try Inbox(context: otherStore.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        try await store.context.database.writer.writeWithoutTransaction { db in
            try db.execute(sql: """
                PRAGMA synchronous = NORMAL;
                PRAGMA fullfsync = OFF;
                PRAGMA checkpoint_fullfsync = OFF;
                CREATE TRIGGER require_durable_reservation BEFORE INSERT ON mac_copy_inbox
                WHEN (SELECT synchronous FROM pragma_synchronous) != 2
                  OR (SELECT fullfsync FROM pragma_fullfsync) != 1
                  OR (SELECT checkpoint_fullfsync FROM pragma_checkpoint_fullfsync) != 1
                BEGIN SELECT RAISE(ABORT, 'reservation is not durable'); END;
                CREATE TRIGGER require_durable_prefix_or_receipt BEFORE UPDATE ON mac_copy_inbox
                WHEN (SELECT synchronous FROM pragma_synchronous) != 2
                  OR (SELECT fullfsync FROM pragma_fullfsync) != 1
                  OR (SELECT checkpoint_fullfsync FROM pragma_checkpoint_fullfsync) != 1
                BEGIN SELECT RAISE(ABORT, 'prefix or receipt is not durable'); END;
                """)
        }
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        try await upload(fixture.text, .transcript, to: otherInbox, offer: fixture.offer)
        let receipt = try await inbox.finalize(fixture.offer, decodeTranscript: Self.decode)
        let resumed = try await otherInbox.reserve(fixture.offer)
        XCTAssertEqual(resumed.receipt, receipt)
        let restored = try await store.context.database.writer.writeWithoutTransaction { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous")
        }
        XCTAssertEqual(restored, 1, "Durability must be scoped to the serialized transaction")
        let next = try makeOffer(audio: Data([1]))
        _ = try await inbox.reserve(next.offer)
        try await inbox.cancel(next.offer)
    }

    func testCancellationDuringFinalizeRollsBackReceiptAndMeeting() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let fixture = try makeOffer(audio: makeAudio(root))
        let audio = try Data(contentsOf: root.appendingPathComponent("fixture.m4a"))
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        try await upload(fixture.text, .transcript, to: inbox, offer: fixture.offer)
        let task = Task {
            try await inbox.finalize(fixture.offer) { bytes in
                withUnsafeCurrentTask { task in
                    XCTAssertNotNil(task, "Synchronous writer must retain caller cancellation context")
                    task?.cancel()
                }
                return try Self.decode(bytes)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must abort the durable transaction")
        } catch is CancellationError {}
        let status = try await inbox.status(fixture.offer)
        XCTAssertNil(status.receipt)
        let items = try await store.load()
        XCTAssertTrue(items.isEmpty)
    }

    func testCancellationImmediatelyBeforeReceiptCommitRollsBackEmptyTranscriptImport() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try makeOffer(audio: audio)
        _ = try await inbox.reserve(fixture.offer)
        try await upload(audio, .audio, to: inbox, offer: fixture.offer)
        try await upload(fixture.text, .transcript, to: inbox, offer: fixture.offer)
        try await store.context.database.writer.write { db in
            db.add(function: DatabaseFunction("cancel_copy_at_receipt", argumentCount: 0) { _ in
                withUnsafeCurrentTask {
                    XCTAssertNotNil($0)
                    $0?.cancel()
                }
                return 0
            })
            try db.execute(sql: """
                CREATE TRIGGER cancel_before_receipt AFTER UPDATE OF receipt ON mac_copy_inbox
                BEGIN SELECT cancel_copy_at_receipt(); END
                """)
        }
        let task = Task {
            try await inbox.finalize(fixture.offer) { bytes in
                let transcript = try Self.decode(bytes)
                return Inbox.Transcript(revision: transcript.revision, parentRevision: transcript.parentRevision,
                                        locale: transcript.locale, segments: [])
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation at the last SQL mutation must roll back receipt and meeting")
        } catch is CancellationError {}
        let status = try await inbox.status(fixture.offer)
        XCTAssertNil(status.receipt)
        XCTAssertEqual(status.audio.offset, audio.count)
        let items = try await store.load()
        XCTAssertTrue(items.isEmpty)
    }

    func testDiscardPendingRecoversSlotsAndOwnedLinksWithoutDeletingCommittedOrForeignAudio() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let audio = try makeAudio(root)
        let committed = try makeOffer(audio: audio)
        _ = try await inbox.reserve(committed.offer)
        try await upload(audio, .audio, to: inbox, offer: committed.offer)
        try await upload(committed.text, .transcript, to: inbox, offer: committed.offer)
        let receipt = try await inbox.finalize(committed.offer, decodeTranscript: Self.decode)
        let committedURL = try store.audioFiles.url(for: committed.offer.manifest.meetingID.lowercased())
        try await store.context.database.writer.write { db in
            try db.execute(sql: "UPDATE mac_copy_inbox SET lastActivity = 0 WHERE operation = ?",
                           arguments: [committed.offer.operationID.uuidString])
        }
        _ = try Inbox(context: store.context)

        let interrupted = try makeOffer(audio: audio)
        _ = try await inbox.reserve(interrupted.offer)
        try await upload(audio, .audio, to: inbox, offer: interrupted.offer)
        try await upload(interrupted.text, .transcript, to: inbox, offer: interrupted.offer)
        try await store.context.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER interrupt_pending_import BEFORE INSERT ON meeting
                BEGIN SELECT RAISE(ABORT, 'injected pending import failure'); END
                """)
        }
        do {
            _ = try await inbox.finalize(interrupted.offer, decodeTranscript: Self.decode)
            XCTFail("Expected interrupted import")
        } catch is DatabaseError {}
        try await store.context.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER interrupt_pending_import")
        }
        let ownedURL = try store.audioFiles.url(for: interrupted.offer.manifest.meetingID.lowercased())
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))
        var pending = [interrupted.offer]
        for _ in 0..<3 {
            let fixture = try makeOffer(audio: Data([1]))
            pending.append(fixture.offer)
            _ = try await inbox.reserve(fixture.offer)
        }
        let foreignOffer = pending[1]
        let foreignURL = try store.audioFiles.url(for: foreignOffer.manifest.meetingID.lowercased())
        try Data([99]).write(to: foreignURL)
        let foreignStage = root.appendingPathComponent("MacMeetingCopyInbox")
            .appendingPathComponent(foreignOffer.operationID.uuidString + ".m4a")
        try Data([1]).write(to: foreignStage)

        let next = try makeOffer(audio: Data([1]))
        await expect(.quotaExceeded) { _ = try await inbox.reserve(next.offer) }
        try await inbox.discardPending()
        try await inbox.discardPending()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignStage.path))
        XCTAssertEqual(try Data(contentsOf: foreignURL), Data([99]))
        XCTAssertEqual(try Data(contentsOf: committedURL), audio)
        let replay = try await inbox.reserve(committed.offer)
        XCTAssertEqual(replay.receipt, receipt)
        let items = try await store.load()
        XCTAssertEqual(items.map(\.id), [committed.offer.manifest.meetingID])
        for offer in pending {
            await expect(.cancelled) { _ = try await inbox.reserve(offer) }
        }
        let fresh = try await inbox.reserve(next.offer)
        XCTAssertNil(fresh.receipt)
        XCTAssertEqual(fresh.audio.offset, 0)
    }

    func testSevenDayExpiryOnReserveAndStartupRetainsBindingsAndRefreshesAcceptedActivity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        var offers: [Inbox.Offer] = []
        for _ in 0..<4 {
            let fixture = try makeOffer(audio: Data([1, 2]))
            offers.append(fixture.offer)
            _ = try await inbox.reserve(fixture.offer)
        }
        let old = Date().timeIntervalSince1970 - Inbox.pendingLifetime - 60
        let expired = Array(offers.prefix(2))
        try await store.context.database.writer.write { db in
            for offer in expired {
                try db.execute(sql: "UPDATE mac_copy_inbox SET lastActivity = ? WHERE operation = ?",
                               arguments: [old, offer.operationID.uuidString])
            }
        }
        let next = try makeOffer(audio: Data([3]))
        _ = try await inbox.reserve(next.offer)
        for offer in expired {
            await expect(.cancelled) { _ = try await inbox.reserve(offer) }
        }
        let recent = offers[2]
        let notExpired = Date().timeIntervalSince1970 - Inbox.pendingLifetime + 3600
        try await store.context.database.writer.write { db in
            try db.execute(sql: "UPDATE mac_copy_inbox SET lastActivity = ? WHERE operation = ?",
                           arguments: [notExpired, recent.operationID.uuidString])
        }
        let beforeAppend = Date().timeIntervalSince1970
        _ = try await inbox.append(Data([1]), asset: .audio, offset: 0,
                                   sha256: hash(Data([1])), offer: recent)
        let updated = try await store.context.database.reader.read { db in
            try Double.fetchOne(db, sql: "SELECT lastActivity FROM mac_copy_inbox WHERE operation = ?",
                                arguments: [recent.operationID.uuidString])
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(updated), beforeAppend)
        try await store.context.database.writer.write { db in
            try db.execute(sql: "UPDATE mac_copy_inbox SET lastActivity = ? WHERE operation = ?",
                           arguments: [old, next.offer.operationID.uuidString])
        }
        let reopened = try MacLibraryStore(directory: root)
        let restarted = try Inbox(context: reopened.context)
        await expect(.cancelled) { _ = try await restarted.reserve(next.offer) }
        let resumed = try await restarted.reserve(recent)
        XCTAssertEqual(resumed.audio.offset, 1)
        let replacement = try makeOffer(audio: Data([4]))
        _ = try await restarted.reserve(replacement.offer)
    }

    func testExistingInboxSchemaGetsActivityClockWithoutDiscardingPendingBinding() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try Inbox(context: store.context)
        let fixture = try makeOffer(audio: Data([1]))
        _ = try await inbox.reserve(fixture.offer)
        try await store.context.database.writer.write { db in
            try db.execute(sql: "ALTER TABLE mac_copy_inbox DROP COLUMN lastActivity")
        }
        let reopened = try MacLibraryStore(directory: root)
        let restarted = try Inbox(context: reopened.context)
        let status = try await restarted.reserve(fixture.offer)
        XCTAssertNil(status.receipt)
        let timestamp = try await reopened.context.database.reader.read { db in
            try Double.fetchOne(db, sql: "SELECT lastActivity FROM mac_copy_inbox WHERE operation = ?",
                                arguments: [fixture.offer.operationID.uuidString])
        }
        XCTAssertGreaterThan(try XCTUnwrap(timestamp), Date().timeIntervalSince1970 - 60)
        _ = try Inbox(context: reopened.context)
    }

    private func expect(_ expected: Inbox.Failure, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? Inbox.Failure, expected, "\(error)")
        }
    }

    private func makeRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let root = support.resolvingSymlinksInPath()
            .appendingPathComponent("mac-copy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeAudio(_ root: URL) throws -> Data {
        let url = root.appendingPathComponent("fixture.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.05
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ])
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    private func makeOffer(
        audio: Data, id: String = UUID().uuidString, title: String = "iPhone meeting"
    ) throws -> (offer: Inbox.Offer, text: Data, segmentID: String) {
        let revision = UUID().uuidString.lowercased()
        let segmentID = UUID().uuidString.lowercased()
        // A tiny test-only codec. No provisional iPhone schema is imported or frozen here.
        let text = try JSONSerialization.data(withJSONObject: [
            "revision": revision, "id": segmentID, "text": "Hello from the iPhone"
        ], options: [.sortedKeys])
        let manifest = Inbox.Manifest(
            meetingID: id, title: title, startedAtMs: 1_700_000_000_000,
            createdAtMs: 1_700_000_000_000, updatedAtMs: 1_700_000_001_000,
            durationMs: 500, locale: "en-US", originDeviceID: "iphone-test",
            audio: Inbox.Asset(byteCount: audio.count, sha256: hash(audio)),
            transcript: Inbox.Asset(byteCount: text.count, sha256: hash(text)),
            revision: revision, parentRevision: nil, source: "publishedLocalTranscript"
        )
        let snapshot = Data("test snapshot \(id) \(revision)".utf8)
        return (Inbox.Offer(
            peerIdentity: Data(repeating: 1, count: 32), receiverIdentity: Data(repeating: 9, count: 32),
            operationID: UUID(), manifestSnapshot: snapshot, manifestSHA256: hash(snapshot), manifest: manifest
        ), text, segmentID)
    }

    private nonisolated static func decode(_ data: Data) throws -> Inbox.Transcript {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let revision = object["revision"], let id = object["id"], let text = object["text"] else {
            throw Inbox.Failure.invalidTranscript
        }
        return Inbox.Transcript(revision: revision, parentRevision: nil, locale: "en-US", segments: [
            Inbox.Segment(id: id, startMs: 0, endMs: 400, text: text, locale: "en-US",
                          revision: 3, source: "appleSpeech")
        ])
    }

    private func replacing(
        _ offer: Inbox.Offer, peer: Data? = nil, receiver: Data? = nil,
        operation: UUID? = nil, snapshot: Data? = nil
    ) -> Inbox.Offer {
        let bytes = snapshot ?? offer.manifestSnapshot
        return Inbox.Offer(peerIdentity: peer ?? offer.peerIdentity, receiverIdentity: receiver ?? offer.receiverIdentity,
                           operationID: operation ?? offer.operationID, manifestSnapshot: bytes,
                           manifestSHA256: hash(bytes), manifest: offer.manifest)
    }

    private func upload(
        _ bytes: Data, _ asset: Inbox.AssetKind, to inbox: Inbox, offer: Inbox.Offer, from start: Int = 0
    ) async throws {
        var offset = start
        var digest = IncrementalSHA256()
        digest.update(Data(bytes.prefix(start)))
        while offset < bytes.count {
            let end = min(offset + Inbox.chunkLimit, bytes.count)
            let chunk = bytes.subdata(in: offset..<end)
            let acknowledged = try await inbox.append(chunk, asset: asset, offset: offset,
                                                       sha256: hash(chunk), offer: offer)
            digest.update(chunk)
            var expected = digest
            XCTAssertEqual(acknowledged, Inbox.Prefix(offset: end, sha256: expected.finalize()))
            offset = end
        }
    }

    private func hash(_ data: Data) -> String {
        var digest = IncrementalSHA256()
        digest.update(data)
        return digest.finalize()
    }
}
