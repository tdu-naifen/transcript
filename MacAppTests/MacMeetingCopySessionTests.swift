import AVFoundation
import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import TranscriptMac

@MainActor
final class MacMeetingCopySessionTests: XCTestCase {
    private typealias Wire = MeetingCopyWire
    private typealias Session = MacMeetingCopySession
    private let peer = Data(repeating: 1, count: 32)
    private let receiver = Data(repeating: 2, count: 32)
    private final class Authorization {
        var allowed = false
    }

    func testNegotiatedRoundtripCanonicalTranscriptPrefixACKAndLibraryRAG() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try MacMeetingCopyInbox(context: store.context)
        let audio = try makeAudio(root)
        let fixture = try fixture(audio: audio)
        var progress: [Session.Progress?] = []
        var receipts: [MacMeetingCopyInbox.Receipt] = []
        let session = Session(inbox: inbox, peerIdentity: peer, receiverIdentity: receiver,
                              isAuthorized: { true }, onProgress: { progress.append($0) },
                              onCommit: { receipt in
            let items = try? await store.load()
            XCTAssertEqual(items?.count, 1, "Callback must observe the committed library")
            receipts.append(receipt)
        })
        try await negotiate(session)
        let status = try await rpc(fixture.offer, session)
        XCTAssertEqual(status.type, .status)
        XCTAssertEqual(status.operation, fixture.operation)
        XCTAssertEqual(status.audio, .init(asset: fixture.manifest.audio, offset: 0, prefixSHA256: Wire.hash(Data())))
        XCTAssertEqual(status.transcript, .init(asset: fixture.manifest.transcript, offset: 0, prefixSHA256: Wire.hash(Data())))
        try await upload(fixture, to: session)
        XCTAssertEqual(progress.compactMap { $0 }.last?.receivedBytes, audio.count + fixture.transcript.count)
        XCTAssertTrue(receipts.isEmpty)
        let committed = try await rpc(finalize(fixture.operation), session)
        XCTAssertEqual(committed.type, .committed)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(committed.receiptID, receipts.first?.id.uuidString.lowercased())
        XCTAssertNil(progress.last!)
        let items = try await store.load()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.meeting.originDeviceId, "paired-" + String(repeating: "01", count: 32))
        XCTAssertEqual(item.meeting.audioSHA256, Data(SHA256.hash(data: audio)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(item.utterances.map(\.text), ["A canonical immutable iPhone transcript"])
        XCTAssertEqual(item.utterances.first?.revision, 7)
        XCTAssertNil(item.utterances.first?.speakerId)
        XCTAssertTrue(item.speakers.isEmpty)
        let evidence = try MacAnalysisEvidence.prepare(mode: .rag, question: "iPhone", meetingID: item.id, items: items)
        XCTAssertEqual(evidence.evidence.first?.sourceText, item.utterances.first?.text)
        XCTAssertEqual(evidence.evidence.first?.sourceRevision, 7)
        let url = try store.audioFiles.url(forFileName: XCTUnwrap(item.meeting.audioFileName))
        XCTAssertEqual(try Data(contentsOf: url), audio)
        // Completed operations do not prevent a subsequent explicitly offered copy.
        let next = try self.fixture(audio: audio)
        let nextStatus = try await rpc(next.offer, session)
        XCTAssertEqual(nextStatus.type, .status)
        session.cancel()
    }

    func testDataBeforeCapabilitiesAndDuplicateCapabilityFailClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let fixture = try fixture()
        let session = try makeSession(store)
        await expect(.wrongOrder) { _ = try await self.rpc(fixture.offer, session) }
        await expect(.inactive) { try await self.negotiate(session) }
        let other = try makeSession(store)
        try await negotiate(other)
        await expect(.wrongOrder) { try await self.negotiate(other) }
        XCTAssertEqual(try rowCount(store, "mac_copy_inbox"), 0)
    }

    func testDisabledRevokedAndCancelledSessionsNeverAcceptData() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try MacMeetingCopyInbox(context: store.context)
        let authorization = Authorization()
        let disabled = Session(inbox: inbox, peerIdentity: peer, receiverIdentity: receiver,
                               isAuthorized: { authorization.allowed })
        await expect(.unauthorized) { try await self.negotiate(disabled) }
        authorization.allowed = true
        let revoked = Session(inbox: inbox, peerIdentity: peer, receiverIdentity: receiver,
                              isAuthorized: { authorization.allowed })
        try await negotiate(revoked)
        authorization.allowed = false
        let fixture = try fixture()
        await expect(.unauthorized) { _ = try await self.rpc(fixture.offer, revoked) }
        let cancelled = try makeSession(store)
        try await negotiate(cancelled)
        cancelled.cancel()
        await expect(.inactive) { _ = try await self.rpc(fixture.offer, cancelled) }
        XCTAssertEqual(try rowCount(store, "mac_copy_inbox"), 0)
    }

    func testAuthorizationRecheckedAfterAwaitBeforeStatusOrCommitCallback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try MacMeetingCopyInbox(context: store.context)
        var checks = 0
        var callbacks = 0
        let session = Session(inbox: inbox, peerIdentity: peer, receiverIdentity: receiver,
                              isAuthorized: { checks += 1; return checks < 3 },
                              onCommit: { _ in callbacks += 1 })
        try await negotiate(session)
        let fixture = try fixture()
        await expect(.unauthorized) { _ = try await self.rpc(fixture.offer, session) }
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(try rowCount(store, "meeting"), 0)
    }

    func testTransientAuthorizationReadFailureAfterAwaitClosesInsteadOfStorageResponse() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try MacMeetingCopyInbox(context: store.context)
        var reads = 0
        let session = Session(inbox: inbox, peerIdentity: peer, receiverIdentity: receiver, isAuthorized: {
            reads += 1
            if reads == 3 { throw CocoaError(.fileReadUnknown) }
            return true
        })
        try await negotiate(session)
        let fixture = try fixture()
        await expect(.unauthorized) { _ = try await self.rpc(fixture.offer, session) }
        await expect(.inactive) { try await self.negotiate(session) }
    }

    func testMalformedOversizedAndWrongHashChunksCloseWithoutACK() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let fixture = try fixture(audio: Data(repeating: 255, count: 1024))
        for kind in 0..<3 {
            let session = try makeSession(store)
            try await negotiate(session)
            _ = try await rpc(fixture.offer, session)
            var chunk = chunk(fixture.operation, asset: .audio, offset: 0, bytes: Data([255]))
            if kind == 0 { chunk.bytes = Data(repeating: 255, count: 769); chunk.sha256 = Wire.hash(chunk.bytes!) }
            if kind == 1 { chunk.sha256 = Wire.hash(Data([1])) }
            var text = String(decoding: try Wire.encode(chunk), as: UTF8.self)
            if kind == 2 { text = " " + text }
            let inner = MacPairingMessage(type: Wire.innerType, value: text)
            await expect(.malformedMessage) { _ = try await session.handle(inner) }
        }
        XCTAssertEqual(try rowCount(store, "mac_copy_chunks"), 0)
    }

    func testDuplicateRequestAndOffsetFailClosedButReconnectResumes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let fixture = try fixture(audio: Data(repeating: 8, count: 800))
        let session = try makeSession(store)
        try await negotiate(session)
        _ = try await rpc(fixture.offer, session)
        let first = chunk(fixture.operation, asset: .audio, offset: 0, bytes: Data(fixture.audio.prefix(768)))
        let ack = try await rpc(first, session)
        XCTAssertEqual(ack.prefix?.offset, 768)
        await expect(.replay) { _ = try await self.rpc(first, session) }
        let reconnected = try makeSession(store)
        try await negotiate(reconnected)
        let resumed = try await rpc(fixture.offer, reconnected)
        XCTAssertEqual(resumed.audio?.offset, 768)
        XCTAssertEqual(resumed.audio?.prefixSHA256, Wire.hash(Data(fixture.audio.prefix(768))))
        let repeated = chunk(fixture.operation, asset: .audio, offset: 0, bytes: Data(fixture.audio.prefix(768)))
        await expect(.wrongOffset) { _ = try await self.rpc(repeated, reconnected) }
        let finalSession = try makeSession(store)
        try await negotiate(finalSession)
        _ = try await rpc(fixture.offer, finalSession)
        let tail = chunk(fixture.operation, asset: .audio, offset: 768, bytes: Data(fixture.audio.dropFirst(768)))
        let tailAck = try await rpc(tail, finalSession)
        XCTAssertEqual(tailAck.prefix?.offset, 800)
        XCTAssertEqual(tailAck.prefix?.prefixSHA256, fixture.manifest.audio.sha256)
    }

    func testChangedOperationManifestAndAuthenticatedPeerCannotRebind() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let fixture = try fixture()
        let session = try makeSession(store)
        try await negotiate(session)
        _ = try await rpc(fixture.offer, session)
        let changedOperation = Wire.Operation(id: UUID().uuidString.lowercased(), meetingID: fixture.operation.meetingID,
                                             manifestSHA256: fixture.operation.manifestSHA256)
        await expect(.operationMismatch) { _ = try await self.rpc(self.finalize(changedOperation), session) }
        let changedPeer = try makeSession(store, peer: Data(repeating: 3, count: 32))
        try await negotiate(changedPeer)
        let denied = try await rpc(fixture.offer, changedPeer)
        XCTAssertEqual(denied.type, .failed)
        XCTAssertEqual(denied.failure, .invalid)
        XCTAssertNil(denied.audio)
        XCTAssertNil(denied.receiptID)
        let changed = try self.fixture(meetingID: fixture.manifest.meetingID, operationID: fixture.operation.id)
        let changedManifestSession = try makeSession(store)
        try await negotiate(changedManifestSession)
        let rebound = try await rpc(changed.offer, changedManifestSession)
        XCTAssertEqual(rebound.failure, .invalid)
        let collisionSession = try makeSession(store)
        try await negotiate(collisionSession)
        var collision = fixture.offer
        collision.operation = changedOperation
        let conflict = try await rpc(collision, collisionSession)
        XCTAssertEqual(conflict.failure, .conflict)
        XCTAssertEqual(try rowCount(store, "mac_copy_inbox"), 1)
    }

    func testLocalAudioLimitAndActiveQuotaFailStorageBeforeStatus() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let oversized = try fixture(audioLength: UInt64(MacMeetingCopyInbox.audioLimit) + 1)
        let session = try makeSession(store)
        try await negotiate(session)
        let rejected = try await rpc(oversized.offer, session)
        XCTAssertEqual(rejected.type, .failed)
        XCTAssertEqual(rejected.operation, oversized.operation)
        XCTAssertEqual(rejected.failure, .storage)
        XCTAssertNil(rejected.audio)
        XCTAssertEqual(try rowCount(store, "mac_copy_inbox"), 0)
        for _ in 0..<4 {
            let next = try makeSession(store)
            try await negotiate(next)
            let status = try await rpc(try fixture().offer, next)
            XCTAssertEqual(status.type, .status)
            next.cancel()
        }
        let quota = try await rpc(try fixture().offer, session)
        XCTAssertEqual(quota.failure, .storage)
        XCTAssertEqual(try rowCount(store, "mac_copy_inbox"), 4)
    }

    func testFailureCallbackReceivesOnlyFixedSemanticFailuresAndNeverCommit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try MacMeetingCopyInbox(context: store.context)
        var failures: [Wire.Failure] = []
        var commits = 0
        var progress: Session.Progress?
        let session = Session(
            inbox: inbox, peerIdentity: peer, receiverIdentity: receiver, isAuthorized: { true },
            onProgress: { progress = $0 }, onCommit: { _ in commits += 1 },
            onFailure: { failures.append($0) }
        )
        try await negotiate(session)
        XCTAssertTrue(failures.isEmpty)
        let oversized = try fixture(audioLength: UInt64(MacMeetingCopyInbox.audioLimit) + 1)
        let storage = try await rpc(oversized.offer, session)
        XCTAssertEqual(storage.failure, .storage)
        XCTAssertEqual(failures, [.storage])
        XCTAssertNil(progress)

        let incomplete = try fixture()
        _ = try await rpc(incomplete.offer, session)
        XCTAssertNotNil(progress)
        let invalid = try await rpc(finalize(incomplete.operation), session)
        XCTAssertEqual(invalid.failure, .invalid)
        XCTAssertEqual(failures, [.storage, .invalid])
        XCTAssertNil(progress)
        XCTAssertEqual(commits, 0)
        session.cancel()
        XCTAssertEqual(failures, [.storage, .invalid], "Local cancellation is not a fabricated protocol failure")
    }

    func testLostReceiptReplayRestartAndDeletionNeverResurrect() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let fixture = try fixture(audio: makeAudio(root))
        let session = try makeSession(store)
        try await negotiate(session)
        _ = try await rpc(fixture.offer, session)
        try await upload(fixture, to: session)
        let committed = try await rpc(finalize(fixture.operation), session)
        let reopened = try MacLibraryStore(directory: root)
        let replaySession = try makeSession(reopened)
        try await negotiate(replaySession)
        let replay = try await rpc(fixture.offer, replaySession)
        XCTAssertEqual(replay.receiptID, committed.receiptID)
        try await reopened.context.database.writer.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [fixture.operation.meetingID])
        }
        let audioURL = try reopened.audioFiles.url(for: fixture.operation.meetingID)
        try FileManager.default.removeItem(at: audioURL)
        var freshOffer = fixture.offer
        freshOffer = copyOffer(freshOffer)
        let historical = try await rpc(freshOffer, replaySession)
        XCTAssertEqual(historical.receiptID, committed.receiptID)
        XCTAssertEqual(try rowCount(reopened, "meeting"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        let otherOperation = try self.fixture(audio: fixture.audio, meetingID: fixture.operation.meetingID)
        let rejected = try await rpc(otherOperation.offer, replaySession)
        XCTAssertEqual(rejected.failure, .conflict)
    }

    func testNoncanonicalOrMismatchedTranscriptAndDatabaseFailureNeverInvokeCommitCallback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let inbox = try MacMeetingCopyInbox(context: store.context)
        let audio = try makeAudio(root)
        var commits = 0
        var failures: [Wire.Failure] = []
        for kind in 0..<3 {
            let good = try fixture(audio: audio)
            let data: Data
            if kind == 0 { data = Data([0x20]) + good.transcript }
            else if kind == 1 { data = try Wire.encode(Wire.Transcript(revision: UUID().uuidString.lowercased(),
                                                                     parentRevision: nil, locale: "en-US", utterances: [])) }
            else { data = good.transcript }
            let fixture = try self.fixture(audio: audio, transcriptBytes: data,
                                           revision: good.manifest.transcriptRevision)
            let session = Session(inbox: inbox, peerIdentity: peer, receiverIdentity: receiver,
                                  isAuthorized: { true }, onCommit: { _ in commits += 1 },
                                  onFailure: { failures.append($0) })
            try await negotiate(session)
            _ = try await rpc(fixture.offer, session)
            try await upload(fixture, to: session)
            if kind == 2 {
                try await store.context.database.writer.write { db in
                    try db.execute(sql: """
                        CREATE TRIGGER reject_wire_commit BEFORE UPDATE OF receipt ON mac_copy_inbox
                        BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END
                        """)
                }
            }
            let failure = try await rpc(finalize(fixture.operation), session)
            XCTAssertEqual(failure.type, .failed)
            XCTAssertEqual(failure.failure, kind == 2 ? .storage : .invalid)
            XCTAssertNil(failure.receiptID)
            XCTAssertEqual(commits, 0)
            XCTAssertEqual(failures.last, kind == 2 ? .storage : .invalid)
            XCTAssertEqual(failures.count, kind + 1)
            XCTAssertEqual(try rowCount(store, "meeting"), 0)
        }
    }

    func testZeroDurationValidShortAudioAndEmptyTranscriptCanCommit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let fixture = try fixture(audio: makeAudio(root), duration: 0)
        let session = try makeSession(store)
        try await negotiate(session)
        _ = try await rpc(fixture.offer, session)
        try await upload(fixture, to: session)
        let receipt = try await rpc(finalize(fixture.operation), session)
        XCTAssertEqual(receipt.type, .committed)
        let items = try await store.load()
        XCTAssertEqual(items.first?.meeting.durationMs, 0)
    }

    func testCancelledCallerCannotReserveOrFinalizeAndCallbackCannotReturnSuccessAfterCancellation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MacLibraryStore(directory: root)
        let session = try makeSession(store)
        try await negotiate(session)
        let fixture = try fixture()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await rpc(fixture.offer, session)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled caller cannot reserve") }
        catch is CancellationError {}
        XCTAssertEqual(try rowCount(store, "mac_copy_inbox"), 0)

        let inbox = try MacMeetingCopyInbox(context: store.context)
        var callbackCount = 0
        let committedSession = Session(inbox: inbox, peerIdentity: peer, receiverIdentity: receiver,
                                       isAuthorized: { true }, onCommit: { _ in
            callbackCount += 1
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let valid = try self.fixture(audio: makeAudio(root))
        try await negotiate(committedSession)
        _ = try await rpc(valid.offer, committedSession)
        try await upload(valid, to: committedSession)
        let task = Task { try await rpc(finalize(valid.operation), committedSession) }
        do { _ = try await task.value; XCTFail("Cancellation after callback cannot emit success") }
        catch is CancellationError {}
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(try rowCount(store, "meeting"), 1, "Cancellation cannot roll back an already durable receipt")
    }

    func testActualEncryptedWorstCase768ByteChunkFits4096Frame() throws {
        let local = Curve25519.KeyAgreement.PrivateKey()
        let remote = Curve25519.KeyAgreement.PrivateKey()
        let shared = try local.sharedSecretFromKeyAgreement(with: remote.publicKey)
        let transcript = Data(repeating: 255, count: 32)
        var sender = MacPairingCipher(secret: shared, transcript: transcript, server: false)
        var receiver = MacPairingCipher(secret: shared, transcript: transcript, server: true)
        let fixture = try fixture()
        var largest = 0
        for _ in 0..<100 {
            let request = chunk(fixture.operation, asset: .transcript, offset: UInt64(Wire.transcriptLimit - 768),
                                bytes: Data(repeating: 255, count: 768))
            let frame = try sender.seal(Wire.inner(request))
            let serialized = try JSONEncoder().encode(frame)
            largest = max(largest, serialized.count)
            XCTAssertLessThanOrEqual(serialized.count, 4096)
            XCTAssertEqual(try Wire.message(receiver.open(frame)), request)
        }
        XCTAssertGreaterThan(largest, 3000, "Measure the encrypted outer JSON, not just raw payload")
        let oversized = chunk(fixture.operation, asset: .audio, offset: 0, bytes: Data(repeating: 255, count: 1024))
        let raw = MacPairingMessage(type: Wire.innerType, value: String(decoding: try Wire.encode(oversized), as: UTF8.self))
        let tooLarge = try JSONEncoder().encode(sender.seal(raw))
        XCTAssertGreaterThan(tooLarge.count, 4096)
        XCTAssertThrowsError(try Wire.inner(oversized))
    }

    private struct Fixture {
        let audio: Data
        let transcript: Data
        let manifest: Wire.Manifest
        let operation: Wire.Operation
        let offer: Wire.Message
    }

    private func fixture(
        audio: Data = Data([1, 2, 3]), audioLength: UInt64? = nil,
        meetingID: String = UUID().uuidString.lowercased(),
        operationID: String = UUID().uuidString.lowercased(),
        transcriptBytes: Data? = nil, revision: String = UUID().uuidString.lowercased(), duration: Int64 = 500
    ) throws -> Fixture {
        let transcript = try transcriptBytes ?? Wire.encode(Wire.Transcript(
            revision: revision, parentRevision: nil, locale: "en-US", utterances: duration == 0 ? [] : [
                Wire.Utterance(id: UUID().uuidString.lowercased(), startMs: 0, endMs: 400,
                               text: "A canonical immutable iPhone transcript", locale: "en-US", revision: 7, source: "appleSpeech")
            ]
        ))
        let manifest = Wire.Manifest(
            meetingID: meetingID, title: "iPhone immutable copy", startedAtMs: 1_700_000_000_000,
            createdAtMs: 1_700_000_000_000, updatedAtMs: 1_700_000_000_500, durationMs: duration, locale: "en-US",
            audio: .init(length: audioLength ?? UInt64(audio.count), sha256: Wire.hash(audio)),
            transcript: .init(length: UInt64(transcript.count), sha256: Wire.hash(transcript)),
            transcriptRevision: revision, parentRevision: nil, source: "publishedLocalTranscript"
        )
        let bytes = try Wire.encode(manifest)
        let operation = Wire.Operation(id: operationID, meetingID: meetingID, manifestSHA256: Wire.hash(bytes))
        var offer = Wire.Message(.offer)
        offer.operation = operation
        offer.manifest = bytes
        return Fixture(audio: audio, transcript: transcript, manifest: manifest, operation: operation, offer: offer)
    }

    private func makeSession(_ store: MacLibraryStore, peer: Data? = nil) throws -> Session {
        Session(inbox: try MacMeetingCopyInbox(context: store.context), peerIdentity: peer ?? self.peer,
                receiverIdentity: receiver, isAuthorized: { true })
    }

    private func negotiate(_ session: Session) async throws {
        var request = Wire.Message(.capabilities)
        request.capability = Wire.capability
        let response = try await rpc(request, session)
        XCTAssertEqual(response.type, .accepted)
        XCTAssertEqual(response.capability, Wire.capability)
        XCTAssertNil(response.operation)
    }

    private func rpc(_ message: Wire.Message, _ session: Session) async throws -> Wire.Message {
        let response = try await session.handle(Wire.inner(message))
        let decoded = try Wire.message(response)
        XCTAssertEqual(decoded.requestID, message.requestID)
        return decoded
    }

    private func copyOffer(_ offer: Wire.Message) -> Wire.Message {
        var copy = Wire.Message(.offer)
        copy.operation = offer.operation
        copy.manifest = offer.manifest
        return copy
    }

    private func chunk(_ operation: Wire.Operation, asset: Wire.AssetName, offset: UInt64, bytes: Data) -> Wire.Message {
        var request = Wire.Message(.chunk)
        request.operation = operation
        request.asset = asset
        request.offset = offset
        request.bytes = bytes
        request.sha256 = Wire.hash(bytes)
        return request
    }

    private func finalize(_ operation: Wire.Operation) -> Wire.Message {
        var request = Wire.Message(.finalize)
        request.operation = operation
        return request
    }

    private func upload(_ fixture: Fixture, to session: Session) async throws {
        for (asset, data, descriptor) in [
            (Wire.AssetName.audio, fixture.audio, fixture.manifest.audio),
            (.transcript, fixture.transcript, fixture.manifest.transcript)
        ] {
            for offset in stride(from: 0, to: data.count, by: Wire.chunkLimit) {
                let end = min(offset + Wire.chunkLimit, data.count)
                let request = chunk(fixture.operation, asset: asset, offset: UInt64(offset), bytes: data.subdata(in: offset..<end))
                let ack = try await rpc(request, session)
                XCTAssertEqual(ack.type, .ack)
                XCTAssertEqual(ack.operation, fixture.operation)
                XCTAssertEqual(ack.asset, asset)
                XCTAssertNil(ack.audio)
                XCTAssertNil(ack.transcript)
                XCTAssertEqual(ack.prefix, .init(asset: descriptor, offset: UInt64(end),
                                               prefixSHA256: Wire.hash(Data(data.prefix(end)))))
            }
        }
    }

    private func expect(_ expected: Session.Failure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? Session.Failure, expected, "\(error)") }
    }

    private func rowCount(_ store: MacLibraryStore, _ table: String) throws -> Int {
        try store.context.database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func makeRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let root = support.resolvingSymlinksInPath().appendingPathComponent("mac-wire-tests-\(UUID().uuidString)")
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
}
