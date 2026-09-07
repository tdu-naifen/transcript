import AVFoundation
import CryptoKit
import Foundation
import GRDB
import Network
import XCTest
@testable import TranscriptMac

@MainActor
final class MacMeetingCopyConnectionTests: XCTestCase {
    private typealias Wire = MeetingCopyWire

    func testAuthenticatedCopyInterleavesHeartbeatsAndRefreshesDurablePlayableLibrary() async throws {
        let environment = try await Environment()
        defer { environment.stop() }
        let fixture = try fixture(audio: makeAudio(environment.root))
        var factoryCalls = 0
        let server = environment.harness.server
        let controller = environment.controller
        server.makeMeetingCopySession = { [weak server] peer, identity in
            factoryCalls += 1
            XCTAssertEqual(server?.state, .connected)
            XCTAssertEqual(server?.connectedPeer?.publicKey, peer.publicKey)
            return controller.makeSession(peer: peer, receiverIdentity: identity) { [weak server] in
                try server?.isConnectedAndTrusted(peer) ?? false
            }
        }
        let client = try await environment.harness.client()
        defer { client.close() }
        try await client.handshake()
        try await waitUntil { server.confirmation != nil }
        XCTAssertEqual(factoryCalls, 0, "Identity proof alone must not enable receiving")
        server.confirm(requestID: try XCTUnwrap(server.confirmation).id)
        XCTAssertEqual(factoryCalls, 0, "Local approval alone must not enable receiving")
        try await client.send("approve", value: client.code)
        try await client.finish()
        try await waitUntil { server.state == .connected }
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(environment.controller.canReceive)
        let revision = environment.library.revision
        try await negotiate(client)
        let status = try await rpc(fixture.offer, client)
        assertStatus(status, fixture, audioOffset: 0)
        try await upload(fixture, client)
        XCTAssertEqual(controller.progress?.receivedBytes, fixture.audio.count + fixture.transcript.count)
        XCTAssertNil(controller.lastReceipt)
        XCTAssertTrue(environment.library.items.isEmpty)
        let committed = try await rpc(finalize(fixture.operation), client)
        XCTAssertEqual(committed.type, .committed)
        try await heartbeat(client)
        client.close()
        XCTAssertNil(controller.progress)
        XCTAssertNil(controller.errorMessage)
        XCTAssertGreaterThan(environment.library.revision, revision)
        let receipt = try XCTUnwrap(controller.lastReceipt)
        XCTAssertEqual(committed.receiptID, receipt.id.uuidString.lowercased())
        XCTAssertEqual(receipt.operationID.uuidString.lowercased(), fixture.operation.id)
        XCTAssertEqual(receipt.meetingID, fixture.operation.meetingID)
        let item = try XCTUnwrap(environment.library.items.first)
        XCTAssertEqual(environment.library.items.count, 1)
        XCTAssertEqual(item.id, fixture.manifest.meetingID)
        XCTAssertEqual(item.meeting.title, fixture.manifest.title)
        XCTAssertEqual(item.meeting.durationMs, Int(fixture.manifest.durationMs))
        XCTAssertEqual(item.meeting.originDeviceId, "paired-" + hex(client.identity.publicKey.rawRepresentation))
        XCTAssertEqual(item.meeting.audioSHA256, hex(Data(SHA256.hash(data: fixture.audio))))
        XCTAssertEqual(item.utterances.map(\.id), fixture.text.utterances.map(\.id))
        XCTAssertEqual(item.utterances.map(\.text), fixture.text.utterances.map(\.text))
        XCTAssertEqual(item.utterances.map(\.revision), [7])
        XCTAssertEqual(item.utterances.first?.startMs, 0)
        XCTAssertEqual(item.utterances.first?.endMs, 400)
        XCTAssertNil(item.utterances.first?.speakerId)
        XCTAssertTrue(item.speakers.isEmpty)
        let audioURL = try environment.library.audioURL(for: item)
        XCTAssertEqual(try Data(contentsOf: audioURL), fixture.audio)
        let playable = try AVAudioFile(forReading: audioURL)
        XCTAssertGreaterThan(playable.length, 0)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: playable.processingFormat, frameCapacity: 1024))
        try playable.read(into: decoded)
        XCTAssertGreaterThan(decoded.frameLength, 0)
        let reopened = try MacLibraryStore(directory: environment.root)
        let durableItems = try await reopened.load()
        XCTAssertEqual(durableItems.map(\.id), [item.id])
        XCTAssertEqual(try receiptID(reopened.context, fixture.operation), committed.receiptID)
        XCTAssertEqual(try rowCount(reopened.context, "meeting"), 1)
    }

    func testNoTransferFactoryKeepsPairingV1HeartbeatsAndRejectsNewMessagesWithoutRemovingTrust() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await pair(client, harness)
        XCTAssertNil(harness.server.makeMeetingCopySession)
        try await heartbeat(client)
        var request = Wire.Message(.capabilities)
        request.capability = Wire.capability
        try await send(request, client)
        try await assertClosed(client, harness)
        XCTAssertEqual(harness.server.state, .failed(
            MacAuthenticatedConnectionError.unsupportedRequest.localizedDescription
        ))
        XCTAssertEqual(harness.store.savedPeers.map(\.publicKey), [client.identity.publicKey.rawRepresentation])
    }

    func testOfferBeforeCapabilitiesClosesWithoutReservingOrImporting() async throws {
        let environment = try await Environment()
        defer { environment.stop() }
        let client = try await environment.harness.client()
        defer { client.close() }
        try await pair(client, environment.harness)
        let fixture = try fixture()
        try await send(fixture.offer, client)
        try await assertClosed(client, environment.harness)
        XCTAssertEqual(try rowCount(environment.context, "mac_copy_inbox"), 0)
        XCTAssertEqual(try rowCount(environment.context, "meeting"), 0)
        XCTAssertNil(environment.controller.lastReceipt)
        XCTAssertEqual(environment.harness.store.savedPeers.count, 1)
    }

    func testPartialSocketClosureResumesPinnedIdentityAtExactPrefixAndCommits() async throws {
        let environment = try await Environment()
        defer { environment.stop() }
        let fixture = try fixture(audio: makeAudio(environment.root))
        XCTAssertGreaterThan(fixture.audio.count, Wire.chunkLimit)
        let first = try await environment.harness.client()
        defer { first.close() }
        try await pair(first, environment.harness)
        let pin = try XCTUnwrap(first.serverIdentity)
        try await negotiate(first)
        let initial = try await rpc(fixture.offer, first)
        assertStatus(initial, fixture, audioOffset: 0)
        let bytes = Data(fixture.audio.prefix(Wire.chunkLimit))
        let ack = try await rpc(chunk(fixture.operation, asset: .audio, offset: 0, bytes: bytes), first)
        assertACK(ack, fixture, asset: .audio, end: Wire.chunkLimit)
        first.close()
        try await waitUntil { environment.harness.server.connectedPeer == nil }
        XCTAssertNil(environment.controller.progress)
        XCTAssertNil(environment.controller.lastReceipt)
        XCTAssertEqual(try rowCount(environment.context, "meeting"), 0)
        let resumed = try await reconnect(first.identity, pin: pin, harness: environment.harness)
        defer { resumed.close() }
        try await negotiate(resumed)
        let status = try await rpc(fixture.offer, resumed)
        assertStatus(status, fixture, audioOffset: Wire.chunkLimit)
        try await upload(fixture, resumed, audioOffset: Wire.chunkLimit)
        let committed = try await rpc(finalize(fixture.operation), resumed)
        XCTAssertEqual(committed.type, .committed)
        resumed.close()
        XCTAssertEqual(environment.library.items.map(\.id), [fixture.operation.meetingID])
        XCTAssertEqual(try receiptID(environment.context, fixture.operation), committed.receiptID)
        XCTAssertEqual(environment.harness.store.savedPeers.count, 1)
    }

    func testUnreadCommittedReceiptReconnectsToSameReceiptWithoutDuplicateRows() async throws {
        let environment = try await Environment()
        defer { environment.stop() }
        let fixture = try fixture(audio: makeAudio(environment.root))
        let first = try await environment.harness.client()
        defer { first.close() }
        try await pair(first, environment.harness)
        let pin = try XCTUnwrap(first.serverIdentity)
        try await negotiate(first)
        _ = try await rpc(fixture.offer, first)
        try await upload(fixture, first)
        // Deliberately never read the finalize response, as if the sender lost its receipt.
        try await send(finalize(fixture.operation), first)
        try await waitUntil { environment.controller.lastReceipt != nil }
        let originalReceipt = try XCTUnwrap(environment.controller.lastReceipt)
        first.close()
        try await waitUntil { environment.harness.server.connectedPeer == nil }
        let resumed = try await reconnect(first.identity, pin: pin, harness: environment.harness)
        defer { resumed.close() }
        try await negotiate(resumed)
        let historical = try await rpc(fixture.offer, resumed)
        XCTAssertEqual(historical.type, .committed)
        XCTAssertEqual(historical.receiptID, originalReceipt.id.uuidString.lowercased())
        var freshOffer = Wire.Message(.offer)
        freshOffer.operation = fixture.operation
        freshOffer.manifest = fixture.offer.manifest
        let repeated = try await rpc(freshOffer, resumed)
        XCTAssertEqual(repeated.type, .committed)
        XCTAssertEqual(repeated.receiptID, historical.receiptID)
        try await heartbeat(resumed)
        resumed.close()
        let reopened = try MacLibraryStore(directory: environment.root)
        XCTAssertEqual(try rowCount(reopened.context, "meeting"), 1)
        XCTAssertEqual(try rowCount(reopened.context, "utterance"), fixture.text.utterances.count)
        XCTAssertEqual(try rowCount(reopened.context, "mac_copy_inbox"), 1)
        XCTAssertEqual(try receiptID(reopened.context, fixture.operation), historical.receiptID)
        let items = try await reopened.load()
        XCTAssertEqual(items.map(\.id), [fixture.operation.meetingID])
    }

    func testDuplicateChunkWithFreshRequestIDClosesWithoutFalseACK() async throws {
        let environment = try await Environment()
        defer { environment.stop() }
        let fixture = try fixture(audio: Data(repeating: 255, count: 1600))
        let client = try await environment.harness.client()
        defer { client.close() }
        try await pair(client, environment.harness)
        try await negotiate(client)
        _ = try await rpc(fixture.offer, client)
        let bytes = Data(fixture.audio.prefix(Wire.chunkLimit))
        let first = chunk(fixture.operation, asset: .audio, offset: 0, bytes: bytes)
        let ack = try await rpc(first, client)
        assertACK(ack, fixture, asset: .audio, end: Wire.chunkLimit)
        let duplicate = chunk(fixture.operation, asset: .audio, offset: 0, bytes: bytes)
        XCTAssertNotEqual(duplicate.requestID, first.requestID)
        try await send(duplicate, client)
        try await assertClosed(client, environment.harness)
        XCTAssertEqual(try rowCount(environment.context, "mac_copy_chunks"), 1)
        XCTAssertEqual(try rowCount(environment.context, "meeting"), 0)
        XCTAssertNil(try receiptID(environment.context, fixture.operation))
        XCTAssertNil(environment.controller.lastReceipt)
        XCTAssertNil(environment.controller.progress)
    }

    func testDisabledOrRevokedReceivingRejectsNextRPCWithoutReceipt() async throws {
        for initiallyEnabled in [false, true] {
            let environment = try await Environment(enabled: initiallyEnabled)
            defer { environment.stop() }
            let fixture = try fixture()
            let client = try await environment.harness.client()
            defer { client.close() }
            try await pair(client, environment.harness)
            if initiallyEnabled {
                try await negotiate(client)
                _ = try await rpc(fixture.offer, client)
                environment.controller.setEnabled(false)
                try await send(chunk(fixture.operation, asset: .audio, offset: 0, bytes: fixture.audio), client)
            } else {
                var request = Wire.Message(.capabilities)
                request.capability = Wire.capability
                try await send(request, client)
            }
            try await assertClosed(client, environment.harness)
            XCTAssertFalse(environment.controller.canReceive)
            XCTAssertNil(environment.controller.progress)
            XCTAssertNil(environment.controller.lastReceipt)
            XCTAssertEqual(try rowCount(environment.context, "mac_copy_chunks"), 0)
            XCTAssertEqual(try rowCount(environment.context, "meeting"), 0)
            XCTAssertNil(try receiptID(environment.context, fixture.operation))
            XCTAssertEqual(environment.harness.store.savedPeers.count, 1)
        }
    }

    func testUnpairDuringPartialCopyCancelsReceivingAndNeverCommits() async throws {
        let environment = try await Environment()
        defer { environment.stop() }
        let fixture = try fixture(audio: Data(repeating: 7, count: 1600))
        let client = try await environment.harness.client()
        defer { client.close() }
        try await pair(client, environment.harness)
        try await negotiate(client)
        _ = try await rpc(fixture.offer, client)
        _ = try await rpc(chunk(fixture.operation, asset: .audio, offset: 0,
                                bytes: Data(fixture.audio.prefix(Wire.chunkLimit))), client)
        XCTAssertNotNil(environment.controller.progress)
        environment.harness.server.unpair(try XCTUnwrap(environment.harness.server.connectedPeer))
        do {
            _ = try await client.receive()
            XCTFail("Unpair must close the authenticated receiving socket")
        } catch {}
        XCTAssertTrue(environment.harness.store.savedPeers.isEmpty)
        XCTAssertNil(environment.controller.progress)
        XCTAssertNil(environment.controller.lastReceipt)
        XCTAssertEqual(try rowCount(environment.context, "meeting"), 0)
        XCTAssertNil(try receiptID(environment.context, fixture.operation))
    }

    func testOversizedLocalAudioOfferReturnsCorrelatedStorageFailureBeforeStatus() async throws {
        let environment = try await Environment()
        defer { environment.stop() }
        let fixture = try fixture(audioLength: UInt64(MacMeetingCopyInbox.audioLimit) + 1)
        let client = try await environment.harness.client()
        defer { client.close() }
        try await pair(client, environment.harness)
        try await negotiate(client)
        let failure = try await rpc(fixture.offer, client)
        XCTAssertEqual(failure.type, .failed)
        XCTAssertEqual(failure.failure, .storage)
        XCTAssertNil(failure.audio)
        XCTAssertNil(failure.transcript)
        XCTAssertNil(failure.receiptID)
        XCTAssertEqual(try rowCount(environment.context, "mac_copy_inbox"), 0)
        XCTAssertEqual(try rowCount(environment.context, "meeting"), 0)
        XCTAssertNil(environment.controller.lastReceipt)
        XCTAssertNotNil(environment.controller.errorMessage)
        try await heartbeat(client)
        XCTAssertEqual(environment.harness.server.state, .connected)
    }

    func testRealBonjourTXTAdvertisesMeetingCopyOnlyWhenEnabled() async throws {
        let name = "Copy-TXT-\(UUID().uuidString)"
        let service = MacBonjourService(serviceName: name, pairingStore: PairingMemoryStore(), preferences: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: MacBonjourService.serviceType, domain: nil), using: parameters
        )
        let observation = TXTObservation()
        browser.browseResultsChangedHandler = { results, _ in
            let match = results.first {
                if case .service(let candidate, _, _, _) = $0.endpoint { return candidate == name }
                return false
            }
            let present = match != nil
            var value: String?
            if let match, case .bonjour(let record) = match.metadata {
                value = NetService.dictionary(fromTXTRecord: record.data)["meeting-copy"]
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            let advertisedValue = value
            Task { @MainActor in
                observation.present = present
                observation.value = advertisedValue
            }
        }
        browser.start(queue: DispatchQueue(label: "meeting-copy.txt.browser"))
        service.start()
        defer { service.stop(); browser.cancel() }
        try await waitUntil(seconds: 15) { observation.present && service.state == .advertising }
        XCTAssertNil(observation.value)
        XCTAssertFalse(service.advertisesMeetingCopy)
        service.advertiseMeetingCopy(true)
        try await waitUntil(seconds: 15) { observation.present && observation.value == "2" }
        XCTAssertTrue(service.advertisesMeetingCopy)
        service.advertiseMeetingCopy(false)
        try await waitUntil(seconds: 15) {
            observation.present && observation.value == nil && service.state == .advertising
        }
        XCTAssertFalse(service.advertisesMeetingCopy)
        XCTAssertTrue(service.pairing.peers.isEmpty)
    }

    private struct Fixture {
        let audio: Data
        let transcript: Data
        let text: Wire.Transcript
        let manifest: Wire.Manifest
        let operation: Wire.Operation
        let offer: Wire.Message
    }

    @MainActor
    private final class Environment {
        let root: URL
        let library: MacLibraryModel
        let context: MacLibraryContext
        let controller: MacMeetingCopyController
        let harness: PairingHarness

        init(enabled: Bool = true) async throws {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            root = support.resolvingSymlinksInPath()
                .appendingPathComponent("mac-copy-connection-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = MacLibraryModel(directory: root)
            controller = MacMeetingCopyController(preferences: nil)
            do {
                context = try await library.processingContext()
                await controller.prepare(library: library)
                guard controller.isReady else { throw MacPairingError.unavailable }
                controller.setEnabled(enabled)
                harness = try await PairingHarness()
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            let server = harness.server
            let controller = self.controller
            server.makeMeetingCopySession = { [weak server, weak controller] peer, identity in
                controller?.makeSession(peer: peer, receiverIdentity: identity) { [weak server] in
                    try server?.isConnectedAndTrusted(peer) ?? false
                }
            }
        }

        func stop() {
            harness.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private final class TXTObservation {
        var present = false
        var value: String?
    }

    private func fixture(audio: Data = Data([1, 2, 3]), audioLength: UInt64? = nil) throws -> Fixture {
        let revision = UUID().uuidString.lowercased()
        let text = Wire.Transcript(revision: revision, parentRevision: nil, locale: "en-US", utterances: [
            .init(id: UUID().uuidString.lowercased(), startMs: 0, endMs: 400,
                  text: "Canonical iPhone copy over authenticated TCP", locale: "en-US",
                  revision: 7, source: "appleSpeech")
        ])
        let transcript = try Wire.encode(text)
        let manifest = Wire.Manifest(
            meetingID: UUID().uuidString.lowercased(), title: "Immutable connection fixture",
            startedAtMs: 1_700_000_000_000, createdAtMs: 1_700_000_000_000,
            updatedAtMs: 1_700_000_000_500, durationMs: 500, locale: "en-US",
            audio: .init(length: audioLength ?? UInt64(audio.count), sha256: Wire.hash(audio)),
            transcript: .init(length: UInt64(transcript.count), sha256: Wire.hash(transcript)),
            transcriptRevision: revision, parentRevision: nil, source: "publishedLocalTranscript"
        )
        let bytes = try Wire.encode(manifest)
        let operation = Wire.Operation(
            id: UUID().uuidString.lowercased(), meetingID: manifest.meetingID, manifestSHA256: Wire.hash(bytes)
        )
        var offer = Wire.Message(.offer)
        offer.operation = operation
        offer.manifest = bytes
        return Fixture(audio: audio, transcript: transcript, text: text,
                       manifest: manifest, operation: operation, offer: offer)
    }

    private func pair(_ client: PairingReferenceClient, _ harness: PairingHarness) async throws {
        try await client.handshake()
        try await waitUntil { harness.server.confirmation != nil }
        XCTAssertEqual(harness.server.confirmation?.code, client.code)
        harness.server.confirm(requestID: try XCTUnwrap(harness.server.confirmation).id)
        try await client.send("approve", value: client.code)
        try await client.finish()
        try await waitUntil { harness.server.state == .connected }
    }

    private func reconnect(
        _ identity: Curve25519.Signing.PrivateKey, pin: Data, harness: PairingHarness
    ) async throws -> PairingReferenceClient {
        let client = try await harness.client(identity: identity)
        do {
            try await client.handshake(reconnect: true, pin: pin)
            XCTAssertNil(harness.server.confirmation)
            try await client.send("resume")
            try await client.finish()
            try await waitUntil { harness.server.state == .connected }
            XCTAssertEqual(client.serverIdentity, pin)
            return client
        } catch {
            client.close()
            throw error
        }
    }

    private func negotiate(_ client: PairingReferenceClient) async throws {
        var request = Wire.Message(.capabilities)
        request.capability = Wire.capability
        let response = try await rpc(request, client)
        XCTAssertEqual(response.type, .accepted)
        XCTAssertEqual(response.capability, Wire.capability)
    }

    private func send(_ message: Wire.Message, _ client: PairingReferenceClient) async throws {
        let inner = try Wire.inner(message)
        XCTAssertEqual(try Wire.message(inner), message)
        try await client.send(inner.type, value: inner.value)
    }

    private func rpc(_ message: Wire.Message, _ client: PairingReferenceClient) async throws -> Wire.Message {
        try await client.send("ping")
        try await send(message, client)
        try await client.send("ping")
        let before = try await client.receive()
        XCTAssertEqual(before.type, "pong")
        XCTAssertNil(before.value)
        let inner = try await client.receive()
        let response = try Wire.message(inner)
        XCTAssertEqual(response.requestID, message.requestID)
        XCTAssertEqual(response.operation, message.operation)
        XCTAssertEqual(try Wire.encode(response), Data(try XCTUnwrap(inner.value).utf8))
        let after = try await client.receive()
        XCTAssertEqual(after.type, "pong")
        XCTAssertNil(after.value)
        return response
    }

    private func heartbeat(_ client: PairingReferenceClient) async throws {
        try await client.send("ping")
        let pong = try await client.receive()
        XCTAssertEqual(pong.type, "pong")
        XCTAssertNil(pong.value)
    }

    private func chunk(_ operation: Wire.Operation, asset: Wire.AssetName, offset: Int, bytes: Data) -> Wire.Message {
        var message = Wire.Message(.chunk)
        message.operation = operation
        message.asset = asset
        message.offset = UInt64(offset)
        message.bytes = bytes
        message.sha256 = Wire.hash(bytes)
        return message
    }

    private func finalize(_ operation: Wire.Operation) -> Wire.Message {
        var message = Wire.Message(.finalize)
        message.operation = operation
        return message
    }

    private func upload(_ fixture: Fixture, _ client: PairingReferenceClient, audioOffset: Int = 0) async throws {
        XCTAssertEqual(Wire.chunkLimit, 768)
        for (asset, bytes, start) in [
            (Wire.AssetName.audio, fixture.audio, audioOffset), (.transcript, fixture.transcript, 0)
        ] {
            for offset in stride(from: start, to: bytes.count, by: Wire.chunkLimit) {
                let end = min(offset + Wire.chunkLimit, bytes.count)
                let response = try await rpc(chunk(fixture.operation, asset: asset, offset: offset,
                                                   bytes: bytes.subdata(in: offset..<end)), client)
                assertACK(response, fixture, asset: asset, end: end)
            }
        }
    }

    private func assertACK(_ message: Wire.Message, _ fixture: Fixture, asset: Wire.AssetName, end: Int) {
        let descriptor = asset == .audio ? fixture.manifest.audio : fixture.manifest.transcript
        let bytes = asset == .audio ? fixture.audio : fixture.transcript
        XCTAssertEqual(message.type, .ack)
        XCTAssertEqual(message.operation, fixture.operation)
        XCTAssertEqual(message.asset, asset)
        XCTAssertEqual(message.prefix, .init(asset: descriptor, offset: UInt64(end),
                                             prefixSHA256: Wire.hash(Data(bytes.prefix(end)))))
        XCTAssertNil(message.audio)
        XCTAssertNil(message.transcript)
        XCTAssertNil(message.receiptID)
    }

    private func assertStatus(_ message: Wire.Message, _ fixture: Fixture, audioOffset: Int) {
        XCTAssertEqual(message.type, .status)
        XCTAssertEqual(message.operation, fixture.operation)
        XCTAssertEqual(message.audio, .init(asset: fixture.manifest.audio, offset: UInt64(audioOffset),
                                            prefixSHA256: Wire.hash(Data(fixture.audio.prefix(audioOffset)))))
        XCTAssertEqual(message.transcript, .init(asset: fixture.manifest.transcript, offset: 0,
                                                 prefixSHA256: Wire.hash(Data())))
        XCTAssertNil(message.receiptID)
    }

    private func assertClosed(_ client: PairingReferenceClient, _ harness: PairingHarness) async throws {
        do {
            let unexpected = try await client.receive()
            XCTFail("Expected socket closure, not \(unexpected.type); no ACK or receipt may escape")
        } catch {}
        try await waitUntil {
            if case .failed = harness.server.state { return true }
            return false
        }
        XCTAssertNil(harness.server.connectedPeer)
    }

    private func waitUntil(seconds: Int = 3, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<(seconds * 100) {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacPairingError.timedOut
    }

    private func rowCount(_ context: MacLibraryContext, _ table: String) throws -> Int {
        try context.database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func receiptID(_ context: MacLibraryContext, _ operation: Wire.Operation) throws -> String? {
        try context.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT lower(receipt) FROM mac_copy_inbox WHERE operation = ?",
                                arguments: [operation.id.uppercased()])
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
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
