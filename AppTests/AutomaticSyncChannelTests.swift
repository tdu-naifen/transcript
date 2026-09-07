import CryptoKit
import Network
import TranscriptCore
import XCTest
@testable import Transcript

@MainActor
final class AutomaticSyncChannelTests: XCTestCase {
    private typealias Wire = AutomaticSyncRepository.Wire

    func testStaleSettingsCannotAuthorizeAReplacementPeer() async throws {
        let store = PairingStoreProbe()
        let current = MacPairedDevice(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            name: "Current fixture", pairedAt: Date()
        )
        let stale = MacPairedDevice(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            name: "Stale fixture", pairedAt: Date()
        )
        store.saved = [current]
        let client = IOSMacPairingClient(store: store)
        let model = MacConnectionModel(discovery: PairingDiscoveryProbe(endpoint: .hostPort(host: "127.0.0.1", port: 9)))
        model.enablePairing(using: client)
        model.suspendConnection()
        let database = try AppDatabase.inMemory()
        model.installAutomaticSync(database: database)
        defer { model.suspendConnection() }
        do {
            try await model.setAutomaticSyncEnabled(true, for: stale)
            XCTFail("A stale settings view must not grant permission to the current peer")
        } catch {}
        let repository = AutomaticSyncRepository(database)
        let denied = try await repository.status(peerID: AutomaticSyncChannel.peerID(current))
        XCTAssertFalse(denied.enabled)
        try await model.setAutomaticSyncEnabled(true, for: current)
        do {
            try await model.setVoiceprintSyncConsent(.allowed, for: stale)
            XCTFail("Biometric consent must stay bound to the displayed pinned identity")
        } catch {}
        let stillDenied = try await repository.status(peerID: AutomaticSyncChannel.peerID(current))
        XCTAssertEqual(stillDenied.voiceprints, .denied)
        try await model.setVoiceprintSyncConsent(.allowed, for: current)
        let allowed = try await repository.status(peerID: AutomaticSyncChannel.peerID(current))
        XCTAssertEqual(allowed.voiceprints, .allowed)
    }

    func testLegacyDiscoveryDoesNotInstantiateOrProbeAutomaticSync() async throws {
        let client = IOSMacPairingClient(
            store: PairingStoreProbe(),
            timeouts: .init(initial: 2, approval: 2, idle: 2, heartbeat: 0.1)
        )
        var factoryCalled = false
        client.makeAutomaticSyncChannel = { _, _ in factoryCalled = true; return nil }
        var heartbeat = false
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.expect("approve")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            // Any unsolicited new payload fails this frozen peer fixture.
            try await peer.expect("ping")
            heartbeat = true
            try await peer.send(.init(type: "pong"))
            try await peer.waitForClose()
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually {
            if case .awaitingApproval = client.state { return true }
            return false
        }
        client.approve()
        try await pairingEventually { heartbeat }
        try client.startAutomaticSyncOnAuthenticatedConnection()
        XCTAssertFalse(factoryCalled)
    }

    func testInstallingProductionSyncAfterAuthenticationNegotiatesExactlyOnce() async throws {
        let client = IOSMacPairingClient(
            store: PairingStoreProbe(),
            timeouts: .init(initial: 2, approval: 2, idle: 2, heartbeat: 0.1)
        )
        var heartbeats = 0
        var hellos = 0
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.expect("approve")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            while hellos == 0 || heartbeats < 2 {
                let message = try await peer.receive()
                if message.type == "ping" {
                    heartbeats += 1
                    try await peer.send(.init(type: "pong"))
                } else {
                    let hello = try Self.decode(message)
                    XCTAssertEqual(hello.kind, .hello)
                    hellos += 1
                    XCTAssertEqual(hellos, 1)
                    try await peer.send(Self.inner(.init(
                        kind: .accepted, requestID: hello.requestID, capability: Wire.capability
                    )))
                }
            }
            try await peer.waitForClose()
        }
        let endpoint = try await server.start()
        let model = MacConnectionModel(discovery: PairingDiscoveryProbe(endpoint: endpoint))
        model.enablePairing(using: client)
        defer { model.suspendConnection(); client.disconnect(); server.stop() }
        client.connect(to: endpoint, allowAutomaticSyncProbe: true)
        try await pairingEventually {
            if case .awaitingApproval = client.state { return true }
            return false
        }
        client.approve()
        try await pairingEventually { heartbeats > 0 }
        XCTAssertEqual(hellos, 0)
        let database = try AppDatabase.inMemory()
        let repository = AutomaticSyncRepository(database)
        let peer = try XCTUnwrap(model.automaticSyncPeer)
        try await repository.configure(peerID: AutomaticSyncChannel.peerID(peer), enabled: true)
        model.installAutomaticSync(database: database)
        try client.startAutomaticSyncOnAuthenticatedConnection()
        try await pairingEventually { hellos == 1 && heartbeats >= 2 }
        XCTAssertEqual(hellos, 1)
    }

    func testNegotiatedBidirectionalOperationsShareAuthenticatedHeartbeatChannel() async throws {
        let client = IOSMacPairingClient(
            store: PairingStoreProbe(),
            timeouts: .init(initial: 2, approval: 2, idle: 2, heartbeat: 0.1)
        )
        let outgoing = Wire.Operation(
            stamp: .init(counter: 1, deviceID: "phone", operationID: "phone-edit"),
            entity: .meeting, entityID: "meeting", field: "title", value: "Phone edit"
        )
        let incoming = Wire.Operation(
            stamp: .init(counter: 2, deviceID: "mac", operationID: "mac-edit"),
            entity: .meeting, entityID: "meeting", field: "title", value: "Mac edit"
        )
        var acknowledged = false
        var received = false
        var heartbeat = false
        var failed = false
        client.makeAutomaticSyncChannel = { _, send in
            AutomaticSyncChannel(
                storage: .init(
                    isEnabled: { true }, pending: { acknowledged ? [] : [outgoing] },
                    receive: { fragment in
                        XCTAssertEqual(fragment.operationID, incoming.id)
                        received = true
                        return incoming.id
                    },
                    acknowledge: { id in XCTAssertEqual(id, outgoing.id); acknowledged = true }
                ),
                send: send, onFailure: { failed = true }
            )
        }
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.expect("approve")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            let hello = try Self.decode(await peer.receive())
            XCTAssertEqual(hello.kind, .hello)
            try await peer.send(Self.inner(.init(
                kind: .accepted, requestID: hello.requestID, capability: Wire.capability
            )))
            for fragment in try Wire.fragments(for: incoming) {
                try await peer.send(Self.inner(.init(kind: .fragment, fragment: fragment)))
            }
            var incomingAcknowledged = false
            while !acknowledged || !incomingAcknowledged || !heartbeat {
                let inner = try await peer.receive()
                if inner.type == "ping" {
                    heartbeat = true
                    try await peer.send(.init(type: "pong"))
                    continue
                }
                let message = try Self.decode(inner)
                if message.kind == .fragment {
                    let fragment = try XCTUnwrap(message.fragment)
                    XCTAssertEqual(fragment.operationID, outgoing.id)
                    if fragment.offset + fragment.bytes.count == fragment.total {
                        try await peer.send(Self.inner(.init(
                            kind: .ack, requestID: message.requestID, operationID: outgoing.id
                        )))
                    }
                } else if message.kind == .ack {
                    XCTAssertEqual(message.operationID, incoming.id)
                    incomingAcknowledged = true
                } else { XCTFail("Unexpected sync payload") }
            }
            try await peer.waitForClose()
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start(), allowAutomaticSyncProbe: true)
        try await pairingEventually {
            if case .awaitingApproval = client.state { return true }
            return false
        }
        client.approve()
        try await pairingEventually { acknowledged && received && heartbeat }
        XCTAssertFalse(failed)
    }

    func testWorstCaseFragmentFitsFrozenEncryptedFrameLimit() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        var cipher = MacPairingCipher(
            secret: try key.sharedSecretFromKeyAgreement(with: other.publicKey),
            transcript: Data(repeating: 0xff, count: 32), server: false
        )
        let fragment = Wire.Fragment(
            operationID: String(repeating: "/", count: 128),
            offset: 999_999, total: 1_048_576, bytes: Data(repeating: 0xff, count: 768)
        )
        let message = Wire.Message(
            kind: .fragment, requestID: String(repeating: "/", count: 128), fragment: fragment
        )
        let frame = try cipher.seal(Self.inner(message))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(frame).count, MacPairingTransport.maximumFrameSize)
    }

    func testMaximumEscapingResourceChunkFitsFrozenEncryptedFrameLimit() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        var cipher = MacPairingCipher(
            secret: try key.sharedSecretFromKeyAgreement(with: other.publicKey),
            transcript: Data(repeating: 0xff, count: 32), server: false
        )
        for escape in ["/", "\"", "\\"] {
            let message = AutomaticSyncResourceWire.Message(
                kind: .chunk, requestID: String(repeating: escape, count: 128),
                chunk: .init(
                    resourceID: String(repeating: "f", count: 64),
                    offset: 8_589_933_824, total: 8_589_934_592,
                    bytes: Data(repeating: 0xff, count: 768)
                )
            )
            let bytes = try Wire.encode(message)
            _ = try AutomaticSyncResourceWire.decode(bytes)
            let frame = try cipher.seal(.init(
                type: AutomaticSyncResourceWire.messageType, value: String(decoding: bytes, as: UTF8.self)
            ))
            XCTAssertLessThanOrEqual(
                try JSONEncoder().encode(frame).count, MacPairingTransport.maximumFrameSize,
                "Resource frame exceeded frozen limit for request ID escaping"
            )
        }
    }

    private static func inner(_ message: Wire.Message) throws -> MacPairingMessage {
        .init(type: Wire.messageType, value: String(decoding: try Wire.encode(message), as: UTF8.self))
    }

    private static func decode(_ message: MacPairingMessage) throws -> Wire.Message {
        XCTAssertEqual(message.type, Wire.messageType)
        return try Wire.decode(Data(try XCTUnwrap(message.value).utf8))
    }
}
