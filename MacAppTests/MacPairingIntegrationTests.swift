import CryptoKit
import Foundation
import Network
import TranscriptCore
import Security
import XCTest
@testable import TranscriptMac

@MainActor
final class MacPairingIntegrationTests: XCTestCase {
    func testAutomaticReplicationUsesAuthenticatedSocketAndSharesHeartbeatCounters() async throws {
        let macDB = try AppDatabase.inMemory()
        let phoneDB = try AppDatabase.inMemory()
        let macRepository = AutomaticSyncRepository(macDB)
        let phoneRepository = AutomaticSyncRepository(phoneDB)
        let harness = try await PairingHarness()
        defer { harness.stop() }
        harness.server.installAutomaticSync(database: macDB)
        let client = try await harness.client()
        defer { client.close() }
        let phonePeer = MacPairedDevice(
            publicKey: client.identity.publicKey.rawRepresentation, name: "QA phone", pairedAt: Date()
        )
        let macPeer = MacPairedDevice(
            publicKey: harness.store.key.publicKey.rawRepresentation, name: "QA Mac", pairedAt: Date()
        )
        try await macRepository.configure(peerID: AutomaticSyncChannel.peerID(phonePeer), enabled: true)
        try await phoneRepository.configure(peerID: AutomaticSyncChannel.peerID(macPeer), enabled: true)
        try await MeetingRepository(phoneDB).insert(Meeting(
            id: "network-phone", title: "From phone", startedAt: Date(), state: .recorded, originDeviceId: "qa-phone"
        ))
        try await MeetingRepository(macDB).insert(Meeting(
            id: "network-mac", title: "From Mac", startedAt: Date(), state: .recorded, originDeviceId: "qa-mac"
        ))
        try await pair(client, harness)
        var channelFailure = false
        var readFailure: (any Error)?
        var receivedPong = false
        let channel = AutomaticSyncChannel(
            storage: .repository(phoneRepository, peer: macPeer, isTrusted: {
                harness.server.isConnected && client.serverIdentity == macPeer.publicKey
            }),
            send: { try await client.send($0.type, value: $0.value) },
            onFailure: { channelFailure = true }
        )
        let reader = Task {
            do {
                while !Task.isCancelled {
                    let message = try await client.receive()
                    if message.type == "pong" {
                        receivedPong = true
                    } else {
                        try await channel.handle(message)
                    }
                }
            } catch {
                if !Task.isCancelled { readFailure = error }
            }
        }
        defer {
            channel.stop()
            reader.cancel()
        }
        try await channel.negotiate()
        try await client.send("ping")
        for _ in 0..<500 {
            let phone = try await MeetingRepository(phoneDB).fetch(id: "network-mac")
            let mac = try await MeetingRepository(macDB).fetch(id: "network-phone")
            if phone?.title == "From Mac", mac?.title == "From phone", receivedPong { break }
            if readFailure != nil || channelFailure { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let phoneCopy = try await MeetingRepository(phoneDB).fetch(id: "network-mac")
        let macCopy = try await MeetingRepository(macDB).fetch(id: "network-phone")
        XCTAssertEqual(phoneCopy?.title, "From Mac")
        XCTAssertEqual(macCopy?.title, "From phone")
        XCTAssertTrue(receivedPong)
        XCTAssertNil(readFailure)
        XCTAssertFalse(channelFailure)
        XCTAssertTrue(harness.server.isConnected)
        XCTAssertEqual(harness.store.savedPeers.count, 1)
    }

    func testProductionHeartbeatDeadlineAllowsLegacyCadenceButBoundsStaleStatus() {
        XCTAssertGreaterThan(MacPairingServer.defaultIdleTimeout, .seconds(30))
        XCTAssertLessThanOrEqual(MacPairingServer.defaultIdleTimeout, .seconds(45))
    }

    func testSleepClearsOnlineStateAndPinnedClientCanReconnectAfterWake() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let first = try await harness.client()
        defer { first.close() }
        try await pair(first, harness)
        XCTAssertTrue(harness.server.isConnected)
        let identity = first.identity
        let pin = try XCTUnwrap(first.serverIdentity)
        let listener = PairingRecoveryListener()
        let service = MacBonjourService(serviceName: "Office Mac", pairing: harness.server) { _ in listener }
        service.start()
        defer { service.stop() }
        service.suspendForSleep()
        XCTAssertFalse(harness.server.isConnected)
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertEqual(harness.store.savedPeers.count, 1)
        service.resumeAfterWake()
        XCTAssertFalse(harness.server.isConnected, "Waking/discovery is not a live connection")
        XCTAssertFalse(harness.server.allowsNewPairing)
        let resumed = try await harness.client(identity: identity)
        defer { resumed.close() }
        try await resumed.handshake(reconnect: true, pin: pin)
        try await resumed.send("resume")
        try await resumed.finish()
        try await waitUntil { harness.server.isConnected }
        try await resumed.send("ping")
        let pong = try await resumed.receive()
        XCTAssertEqual(pong.type, "pong")
        XCTAssertNil(harness.server.confirmation)
    }

    func testHeartbeatsRefreshOnlineStateAndSilenceExpiresIt() async throws {
        let harness = try await PairingHarness(idleTimeout: .milliseconds(400))
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await pair(client, harness)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(150))
            try await client.send("ping")
            let pong = try await client.receive()
            XCTAssertEqual(pong.type, "pong")
            XCTAssertTrue(harness.server.isConnected)
        }
        try await waitUntil { !harness.server.isConnected }
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertEqual(harness.store.savedPeers.count, 1)
    }

    func testUnsupportedPostPairingRequestReportsCapabilityFailureWithoutLosingTrust() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await pair(client, harness)
        try await client.send("unsupported-feature")
        try await waitUntil { if case .failed = harness.server.state { true } else { false } }
        XCTAssertEqual(harness.server.state, .failed(
            MacAuthenticatedConnectionError.unsupportedRequest.localizedDescription
        ))
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertEqual(harness.store.savedPeers.count, 1)
    }

    func testRemoteClosureAfterPairingReportsDisconnectWithoutLosingTrust() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let client = try await harness.client()
        try await pair(client, harness)
        client.close()
        try await waitUntil { if case .failed = harness.server.state { true } else { false } }
        XCTAssertEqual(harness.server.state, .failed(MacAuthenticatedConnectionError.closed.localizedDescription))
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertEqual(harness.store.savedPeers.count, 1)
    }

    func testMissingHeartbeatHasConnectionSpecificTimeout() async throws {
        let harness = try await PairingHarness(idleTimeout: .milliseconds(100))
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await pair(client, harness)
        try await waitUntil { if case .failed = harness.server.state { true } else { false } }
        XCTAssertEqual(harness.server.state, .failed(MacAuthenticatedConnectionError.idleTimeout.localizedDescription))
        XCTAssertEqual(harness.store.savedPeers.count, 1)
    }

    func testDiscoveryRecoveryDoesNotDisconnectAuthenticatedSocket() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await pair(client, harness)
        let listener = PairingRecoveryListener()
        let service = MacBonjourService(serviceName: "Office Mac", pairing: harness.server) { _ in listener }
        service.start()
        defer { service.stop() }
        let failure = MacBonjourService.Failure.network(.posix(.ENETDOWN))
        for event: MacBonjourListenerEvent in [.waiting(failure), .failed(failure)] {
            listener.emit(.ready)
            listener.emit(.registered("Office Mac"))
            listener.emit(event)
            service.recoverIfNeeded()
            XCTAssertEqual(harness.server.state, .connected)
            XCTAssertFalse(harness.server.allowsNewPairing)
            try await client.send("ping")
            let pong = try await client.receive()
            XCTAssertEqual(pong.type, "pong")
        }
        service.stop()
        XCTAssertEqual(harness.server.state, .idle, "Explicit Stop must still close the session")
    }

    func testRealBonjourEndpointCompletesAuthenticatedPairing() async throws {
        let store = PairingMemoryStore()
        let service = MacBonjourService(
            serviceName: "Pairing-\(UUID().uuidString)", pairingStore: store, preferences: nil
        )
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_vtscribe._tcp", domain: nil), using: parameters)
        let discovery = PairingDiscoveredEndpoint()
        let name = service.serviceName
        let found = expectation(description: "Pairing endpoint is discovered with its network interface")
        browser.browseResultsChangedHandler = { results, _ in
            let endpoint = results.first {
                if case .service(let candidate, _, _, _) = $0.endpoint { return candidate == name }
                return false
            }?.endpoint
            Task { @MainActor in
                if discovery.endpoint == nil, let endpoint {
                    discovery.endpoint = endpoint
                    found.fulfill()
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "pairing.integration.browser"))
        service.start()
        defer { service.stop(); browser.cancel() }
        await fulfillment(of: [found], timeout: 15)
        try await waitUntil { service.state == .advertising }
        let client = PairingReferenceClient(
            connection: NWConnection(
                to: try XCTUnwrap(discovery.endpoint), using: parameters
            ),
            identity: Curve25519.Signing.PrivateKey()
        )
        defer { client.close() }
        try await client.handshake()
        try await waitUntil { service.pairing.confirmation != nil }
        XCTAssertEqual(service.pairing.confirmation?.code, client.code)
        service.pairing.confirm(requestID: try XCTUnwrap(service.pairing.confirmation).id)
        try await client.send("approve", value: client.code)
        try await client.finish()
        try await waitUntil { service.pairing.state == .connected }
        XCTAssertEqual(store.savedPeers.count, 1)
    }

    func testFivePairingAttemptsRequireExplicitReenablement() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        for _ in 0..<5 {
            let client = try await harness.client()
            do { try await client.handshake(tamperReveal: true); XCTFail("Tampered reveal passed") } catch {}
            try await waitUntil { if case .failed = harness.server.state { true } else { false } }
            client.close()
        }
        XCTAssertFalse(harness.server.allowsNewPairing)
        let blocked = try await harness.client()
        do { try await blocked.handshake(); XCTFail("Sixth pairing attempt accepted") } catch {}
        blocked.close()
        harness.server.disconnect()
        harness.server.enablePairing()
        let permitted = try await harness.client()
        defer { permitted.close() }
        try await pair(permitted, harness)
    }

    func testRealKeychainIdentityAndPinsSurviveStoreRecreation() throws {
        let service = "com.transcript.mac.pairing.test.\(UUID().uuidString)"
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true
            ] as CFDictionary)
        }
        let first = MacPairingKeychainStore(service: service)
        let identity = try first.identity().publicKey.rawRepresentation
        let peer = MacPairedDevice(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            name: "Persisted iPhone", pairedAt: Date()
        )
        try first.save(peer)
        let reopened = MacPairingKeychainStore(service: service)
        XCTAssertEqual(try reopened.identity().publicKey.rawRepresentation, identity)
        XCTAssertEqual(try reopened.peers(), [peer])
        try reopened.remove(publicKey: peer.publicKey)
        XCTAssertTrue(try first.peers().isEmpty)
    }

    func testReferenceClientPairsOnlyAfterBothApprovalsAndExchangesEncryptedPing() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await client.handshake()
        try await waitUntil { harness.server.confirmation != nil }
        XCTAssertEqual(harness.server.confirmation?.code, client.code)
        XCTAssertEqual(harness.server.confirmation?.name, "Reference iPhone")
        XCTAssertTrue(harness.store.savedPeers.isEmpty)
        try await client.send("approve", value: client.code)
        harness.server.confirm(requestID: UUID())
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(harness.server.localApproved, "An approval from an old UI request must not approve this one")
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertTrue(harness.store.savedPeers.isEmpty, "Remote approval alone cannot establish trust")
        harness.server.confirm(requestID: try XCTUnwrap(harness.server.confirmation).id)
        try await client.finish()
        try await waitUntil { harness.server.state == .connected }
        XCTAssertEqual(harness.store.savedPeers.first?.publicKey, client.identity.publicKey.rawRepresentation)
        try await client.send("ping")
        let pong = try await client.receive()
        XCTAssertEqual(pong.type, "pong")
    }

    func testLocalApprovalAloneDoesNotPersistTrust() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await client.handshake()
        try await waitUntil { harness.server.confirmation != nil }
        harness.server.confirm(requestID: try XCTUnwrap(harness.server.confirmation).id)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(harness.store.savedPeers.isEmpty)
        XCTAssertNil(harness.server.connectedPeer)
    }

    func testWrongCodeAndRemoteRejectNeverPersistTrust() async throws {
        for reject in [false, true] {
            let harness = try await PairingHarness()
            let client = try await harness.client()
            try await client.handshake()
            try await waitUntil { harness.server.confirmation != nil }
            harness.server.confirm(requestID: try XCTUnwrap(harness.server.confirmation).id)
            try await client.send(reject ? "reject" : "approve", value: reject ? nil : "not-the-code")
            try await waitUntil { if case .failed = harness.server.state { true } else { false } }
            XCTAssertNil(harness.server.connectedPeer)
            XCTAssertTrue(harness.store.savedPeers.isEmpty)
            client.close()
            harness.stop()
        }
    }

    func testLocalRejectionClosesConnectionAndDoesNotPersist() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await client.handshake()
        try await waitUntil { harness.server.confirmation != nil }
        harness.server.reject(requestID: try XCTUnwrap(harness.server.confirmation).id)
        do {
            _ = try await client.receive()
            XCTFail("Rejected socket remained open")
        } catch {}
        XCTAssertTrue(harness.store.savedPeers.isEmpty)
        XCTAssertNil(harness.server.confirmation)
    }

    func testRemoteRejectAfterApprovalInvalidatesPendingMacConfirmation() async throws {
        try await assertRemoteCancellationAfterApproval(disconnect: false)
    }

    func testRemoteDisconnectAfterApprovalInvalidatesPendingMacConfirmation() async throws {
        try await assertRemoteCancellationAfterApproval(disconnect: true)
    }

    private func assertRemoteCancellationAfterApproval(disconnect: Bool) async throws {
        let harness = try await PairingHarness(confirmationTimeout: .seconds(10))
        defer { harness.stop() }
        let client = try await harness.client()
        defer { client.close() }
        try await client.handshake()
        try await waitUntil { harness.server.confirmation != nil }
        let request = try XCTUnwrap(harness.server.confirmation)
        try await client.send("approve", value: client.code)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.server.confirmation?.id, request.id)
        XCTAssertTrue(harness.store.savedPeers.isEmpty)

        let started = ContinuousClock.now
        if disconnect { client.close() }
        else { try await client.send("reject") }
        try await waitUntil { harness.server.confirmation == nil }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "Cancellation must not wait for the UI deadline")
        guard case .failed = harness.server.state else { return XCTFail("Remote cancellation was not observed") }

        harness.server.confirm(requestID: request.id)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(harness.store.savedPeers.isEmpty, "A cancelled peer must never be persisted by a later Mac approval")
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertFalse(harness.server.localApproved)
    }

    func testHandshakeAndApprovalDeadlinesCloseStalledClients() async throws {
        for startHandshake in [false, true] {
            let harness = try await PairingHarness(
                handshakeTimeout: .milliseconds(400), confirmationTimeout: .milliseconds(150)
            )
            let client = try await harness.client()
            if startHandshake { try await client.handshake() }
            try await waitUntil { if case .failed = harness.server.state { true } else { false } }
            XCTAssertNil(harness.server.confirmation)
            XCTAssertTrue(harness.store.savedPeers.isEmpty)
            XCTAssertNil(harness.server.connectedPeer)
            client.close()
            harness.stop()
        }
    }

    func testCommittedHelloTamperingAndWrongIdentityProofAreRejected() async throws {
        for tamperCommitment in [true, false] {
            let harness = try await PairingHarness()
            let client = try await harness.client()
            do {
                try await client.handshake(tamperReveal: tamperCommitment, wrongSignature: !tamperCommitment)
                XCTFail("Invalid handshake succeeded")
            } catch {}
            try await waitUntil { if case .failed = harness.server.state { true } else { false } }
            XCTAssertNil(harness.server.confirmation, "Unauthenticated identity must not produce a code")
            XCTAssertTrue(harness.store.savedPeers.isEmpty)
            client.close()
            harness.stop()
        }
    }

    func testTrustedReconnectPinsIdentityAndUnpairRevokesIt() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let identity = Curve25519.Signing.PrivateKey()
        let first = try await harness.client(identity: identity)
        try await pair(first, harness)
        let serverPin = try XCTUnwrap(first.serverIdentity)
        first.close()
        harness.server.disconnect()
        let reconnect = try await harness.client(identity: identity)
        defer { reconnect.close() }
        try await reconnect.handshake(reconnect: true, pin: serverPin)
        XCTAssertNil(harness.server.confirmation)
        try await reconnect.send("resume")
        try await reconnect.finish()
        try await waitUntil { harness.server.state == .connected }
        let peer = try XCTUnwrap(harness.server.peers.first)
        let database = try AppDatabase.inMemory()
        let repository = AutomaticSyncRepository(database)
        harness.server.installAutomaticSync(database: database)
        try await repository.configure(
            peerID: AutomaticSyncChannel.peerID(peer), enabled: true, voiceprints: .allowed
        )
        await harness.server.unpair(peer)
        let syncStatus = try await repository.status(peerID: AutomaticSyncChannel.peerID(peer))
        XCTAssertFalse(syncStatus.enabled)
        XCTAssertEqual(syncStatus.voiceprints, .revoked)
        XCTAssertTrue(harness.store.savedPeers.isEmpty)
        XCTAssertNil(harness.server.connectedPeer)
        let revoked = try await harness.client(identity: identity)
        defer { revoked.close() }
        do {
            try await revoked.handshake(reconnect: true, pin: serverPin)
            XCTFail("Unpaired identity reconnected")
        } catch {}
    }

    func testReconnectRejectsUnknownClientAndChangedServerIdentity() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        let identity = Curve25519.Signing.PrivateKey()
        let first = try await harness.client(identity: identity)
        try await pair(first, harness)
        let pin = try XCTUnwrap(first.serverIdentity)
        first.close()
        harness.server.disconnect()
        let unknown = try await harness.client()
        do {
            try await unknown.handshake(reconnect: true, pin: pin)
            XCTFail("Unknown identity reconnected")
        } catch {}
        unknown.close()
        harness.server.disconnect()
        let changedPin = try await harness.client(identity: identity)
        defer { changedPin.close() }
        do {
            try await changedPin.handshake(reconnect: true, pin: Data(repeating: 7, count: 32))
            XCTFail("Changed server pin was trusted")
        } catch {}
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertNil(harness.server.confirmation)
    }

    func testReplayAndCiphertextTamperingAreRejected() async throws {
        for replay in [true, false] {
            let harness = try await PairingHarness()
            let client = try await harness.client()
            try await pair(client, harness)
            let frame = try client.seal("ping")
            if replay {
                try await client.transport.send(frame)
                _ = try await client.receive()
                try await client.transport.send(frame)
            } else {
                var corrupt = frame
                var bytes = try XCTUnwrap(Data(base64Encoded: frame.payload ?? ""))
                bytes[bytes.count - 1] ^= 1
                corrupt.payload = bytes.base64EncodedString()
                try await client.transport.send(corrupt)
            }
            try await waitUntil { harness.server.connectedPeer == nil }
            XCTAssertEqual(harness.store.savedPeers.count, 1, "Protocol failure disconnects but does not erase trust")
            client.close()
            harness.stop()
        }
    }

    func testPrivateDataAndOutOfOrderApprovalAreRejectedBeforePairing() async throws {
        for type in ["meeting", "ready"] {
            let harness = try await PairingHarness()
            let client = try await harness.client()
            try await client.handshake()
            try await client.send(type)
            try await waitUntil { if case .failed = harness.server.state { true } else { false } }
            XCTAssertTrue(harness.store.savedPeers.isEmpty)
            XCTAssertNil(harness.server.connectedPeer)
            client.close()
            harness.stop()
        }
    }

    func testOversizedAndPartialFramesAreClosedWithinDeadline() async throws {
        for header in [Data([0, 0, 16, 1]), Data([0, 0])] {
            let harness = try await PairingHarness(handshakeTimeout: .milliseconds(150))
            let client = try await harness.client()
            client.transport.connection.send(content: header, completion: .contentProcessed { _ in })
            try await waitUntil { if case .failed = harness.server.state { true } else { false } }
            XCTAssertTrue(harness.store.savedPeers.isEmpty)
            client.close()
            harness.stop()
        }
    }

    func testKeychainWriteFailureCannotClaimSuccess() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        harness.store.failWrites = true
        let client = try await harness.client()
        defer { client.close() }
        try await client.handshake()
        try await waitUntil { harness.server.confirmation != nil }
        harness.server.confirm(requestID: try XCTUnwrap(harness.server.confirmation).id)
        try await client.send("approve", value: client.code)
        do { try await client.finish(); XCTFail("Storage failure acknowledged success") } catch {}
        XCTAssertNil(harness.server.connectedPeer)
        XCTAssertTrue(harness.store.savedPeers.isEmpty)
    }

    func testNewPairingRequiresExplicitEnablement() async throws {
        let harness = try await PairingHarness()
        defer { harness.stop() }
        harness.server.stop()
        let client = try await harness.client()
        defer { client.close() }
        do { try await client.handshake(); XCTFail("Unarmed pairing succeeded") } catch {}
        XCTAssertTrue(harness.store.savedPeers.isEmpty)
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

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacPairingError.timedOut
    }
}

@MainActor
private final class PairingDiscoveredEndpoint {
    var endpoint: NWEndpoint?
}

@MainActor
final class PairingMemoryStore: MacPairingIdentityStoring {
    let key = Curve25519.Signing.PrivateKey()
    var savedPeers: [MacPairedDevice] = []
    var failWrites = false
    func identity() throws -> Curve25519.Signing.PrivateKey { key }
    func peers() throws -> [MacPairedDevice] { savedPeers }
    func save(_ peer: MacPairedDevice) throws {
        if failWrites { throw MacPairingError.keychain(errSecInteractionNotAllowed) }
        savedPeers.removeAll { $0.publicKey == peer.publicKey }
        savedPeers.append(peer)
    }
    func remove(publicKey: Data) throws { savedPeers.removeAll { $0.publicKey == publicKey } }
}

@MainActor
private final class PairingRecoveryListener: MacBonjourListening {
    private var callback: (@MainActor @Sendable (MacBonjourListenerEvent) -> Void)?
    func start(onEvent: @escaping @MainActor @Sendable (MacBonjourListenerEvent) -> Void) {
        callback = onEvent
    }
    func cancel() {}
    func emit(_ event: MacBonjourListenerEvent) { callback?(event) }
}

@MainActor
final class PairingHarness {
    let store = PairingMemoryStore()
    let server: MacPairingServer
    private let listener: NWListener

    init(
        handshakeTimeout: Duration = .seconds(2),
        confirmationTimeout: Duration = .seconds(2),
        idleTimeout: Duration = .seconds(120)
    ) async throws {
        server = MacPairingServer(
            name: "Reference Mac", store: store,
            handshakeTimeout: handshakeTimeout, confirmationTimeout: confirmationTimeout,
            idleTimeout: idleTimeout
        )
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [server] connection in
            Task { @MainActor in server.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "pairing.integration.listener"))
        for _ in 0..<200 {
            if let port = listener.port, port.rawValue != 0 { server.enablePairing(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacPairingError.timedOut
    }

    func client(identity: Curve25519.Signing.PrivateKey = .init()) async throws -> PairingReferenceClient {
        let port = try XCTUnwrap(listener.port)
        return PairingReferenceClient(
            connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), identity: identity
        )
    }

    func stop() { server.stop(); listener.cancel() }
}

/// Independent CryptoKit client implementing the published byte contract, not the server's crypto helpers.
@MainActor
final class PairingReferenceClient {
    let identity: Curve25519.Signing.PrivateKey
    let transport: MacPairingTransport
    private let prefix = Data("TranscriptPairing/v1/".utf8)
    private var transcript = Data()
    private var outbound: SymmetricKey?
    private var inbound: SymmetricKey?
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var deadline: Task<Void, Never>?
    private var closed = false
    private var protocolStage = "not started"
    private(set) var code = ""
    private(set) var serverIdentity: Data?

    init(connection: NWConnection, identity: Curve25519.Signing.PrivateKey) {
        self.identity = identity
        transport = MacPairingTransport(connection)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if case .ready = state {
                    self.armDeadline(.seconds(5), phase: "authenticated protocol")
                }
            }
        }
        armDeadline(.seconds(15), phase: "Bonjour resolution / TCP establishment")
        transport.start()
    }

    private func armDeadline(_ duration: Duration, phase: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            let stage = self?.protocolStage ?? "client released"
            let connectionState = self.map { String(describing: $0.transport.connection.state) } ?? "unavailable"
            XCTFail("Reference client timed out during \(phase); TCP state: \(connectionState); protocol stage: \(stage). If Bonjour discovery succeeded but no server handshake response arrived, inspect the macOS incoming-connections Firewall prompt and separate Local Network permission. A pre-handshake connectivity failure does not establish a cryptographic regression.")
            self?.transport.cancel()
        }
    }

    func close() {
        closed = true
        deadline?.cancel()
        transport.connection.stateUpdateHandler = nil
        transport.cancel()
    }

    func handshake(reconnect: Bool = false, pin: Data? = nil, tamperReveal: Bool = false, wrongSignature: Bool = false) async throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var nonce = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &nonce) == errSecSuccess else {
            throw MacPairingError.unavailable
        }
        let name = Data("Reference iPhone".utf8)
        var hello = Data([reconnect ? 1 : 0]) + identity.publicKey.rawRepresentation
            + ephemeral.publicKey.rawRepresentation + Data(nonce) + Data([0, UInt8(name.count)]) + name
        let commitment = Data(SHA256.hash(data: prefix + Data("commit/client".utf8) + hello))
        protocolStage = "sending client commitment"
        try await transport.send(.init(type: "commit", payload: commitment.base64EncodedString(), mode: reconnect ? "reconnect" : "pair"))
        protocolStage = "waiting for server commitment"
        let serverCommit = try await transport.receive()
        guard serverCommit.type == "commit", serverCommit.mode == (reconnect ? "reconnect" : "pair"),
              let encoded = serverCommit.payload, let expected = Data(base64Encoded: encoded),
              expected.count == 32 else { throw MacPairingError.invalidMessage }
        if tamperReveal { hello[65] ^= 1 }
        try await transport.send(.init(type: "reveal", payload: hello.base64EncodedString()))
        protocolStage = "waiting for server reveal"
        let reveal = try await transport.receive()
        guard reveal.type == "reveal", let value = reveal.payload, let remote = Data(base64Encoded: value),
              remote.count >= 100, remote[0] == (reconnect ? 1 : 0),
              Data(SHA256.hash(data: prefix + Data("commit/server".utf8) + remote)) == expected else {
            throw MacPairingError.invalidMessage
        }
        let publicKey = Data(remote[1..<33])
        serverIdentity = publicKey
        if reconnect, pin != publicKey { close(); throw MacPairingError.identityMismatch }
        transcript = Data(SHA256.hash(data: prefix + Data("transcript/".utf8) + hello + remote))
        let secret = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(remote[33..<65]))
        )
        func derive(_ name: String, bytes: Int = 32) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: transcript, sharedInfo: prefix + Data(name.utf8), outputByteCount: bytes
            )
        }
        outbound = derive("c2s")
        inbound = derive("s2c")
        let sas = derive("sas", bytes: 8).withUnsafeBytes { bytes in
            bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        code = String(format: "%06llu", sas % 1_000_000)
        let signingKey = wrongSignature ? Curve25519.Signing.PrivateKey() : identity
        let signature = try signingKey.signature(for: prefix + Data("auth/client".utf8) + transcript)
        try await send("auth", value: signature.base64EncodedString())
        protocolStage = "waiting for server identity proof"
        let proof = try await receive()
        guard proof.type == "auth", let proofValue = proof.value,
              let signature = Data(base64Encoded: proofValue),
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(
                signature, for: prefix + Data("auth/server".utf8) + transcript
              ) else { throw MacPairingError.identityMismatch }
        protocolStage = "waiting for bilateral confirmation"
    }

    func finish() async throws {
        protocolStage = "waiting for server ready"
        let ready = try await receive()
        guard ready.type == "ready" else { throw MacPairingError.invalidMessage }
        try await send("ready")
        protocolStage = "authenticated"
    }

    func send(_ type: String, value: String? = nil) async throws {
        try await transport.send(seal(type, value: value))
    }

    func seal(_ type: String, value: String? = nil) throws -> MacPairingFrame {
        var plaintext = ["type": type]
        if let value { plaintext["value"] = value }
        let count = withUnsafeBytes(of: sent.bigEndian) { Data($0) }
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + count)
        let key = try XCTUnwrap(outbound)
        let box = try ChaChaPoly.seal(
            JSONSerialization.data(withJSONObject: plaintext), using: key, nonce: nonce,
            authenticating: prefix + Data("sealed/c2s".utf8) + transcript + count
        )
        defer { sent += 1 }
        return .init(type: "sealed", payload: box.combined.base64EncodedString(), counter: sent)
    }

    func receive() async throws -> MacPairingMessage {
        let frame = try await transport.receive()
        guard frame.type == "sealed", frame.counter == received, let payload = frame.payload,
              let data = Data(base64Encoded: payload) else { throw MacPairingError.invalidMessage }
        let count = withUnsafeBytes(of: received.bigEndian) { Data($0) }
        let box = try ChaChaPoly.SealedBox(combined: data)
        guard Data(box.nonce) == Data(repeating: 0, count: 4) + count else { throw MacPairingError.invalidMessage }
        let plaintext = try ChaChaPoly.open(
            box, using: XCTUnwrap(inbound),
            authenticating: prefix + Data("sealed/s2c".utf8) + transcript + count
        )
        received += 1
        return try JSONDecoder().decode(MacPairingMessage.self, from: plaintext)
    }
}
