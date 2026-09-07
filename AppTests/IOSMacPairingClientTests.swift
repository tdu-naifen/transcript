import CryptoKit
import Network
import XCTest
@testable import Transcript

@MainActor
final class IOSMacPairingClientTests: XCTestCase {
    private let shortTimeouts = IOSMacPairingClient.Timeouts(
        initial: 1, approval: 1, idle: 1, heartbeat: 0.05
    )

    func testModelAdapterPairsWithoutTransferAndPreservesOnlyAuthenticatedPresentation() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        var heartbeatReceived = false
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.expect("approve")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            try await peer.expect("ping")
            heartbeatReceived = true
            try await peer.send(.init(type: "pong"))
            try await peer.waitForClose()
        }
        var pendingClosed = false
        let pendingServer = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.waitForClose()
            pendingClosed = true
        }
        let discovery = PairingDiscoveryProbe(endpoint: try await server.start())
        let model = MacConnectionModel(discovery: discovery)
        model.enablePairing(using: client)
        defer { model.suspendConnection(); server.stop(); pendingServer.stop() }
        await model.perform(.discover)
        await model.perform(.selectDevice(discovery.device.id))
        XCTAssertNil(model.pendingAction, "Socket negotiation cannot occupy the model action gate")
        try await pairingEventually { client.isAwaitingApproval }
        guard case .pairing(let pairing) = model.connection else { return XCTFail("Expected comparison UI") }
        XCTAssertFalse(pairing.confirmedOnPhone)
        XCTAssertFalse(pairing.confirmedOnMac)
        await model.perform(.confirmPairing)
        try await pairingEventually { model.isConnected }
        XCTAssertFalse(model.supportsMeetingTransfer)
        XCTAssertNotNil(model.submissionBlockReason(meetingID: "local-meeting"))
        XCTAssertTrue(model.jobs.isEmpty)
        model.endConnectionPresentation()
        XCTAssertTrue(client.isConnected)
        XCTAssertTrue(model.isConnected)
        try await pairingEventually { heartbeatReceived }

        await model.perform(.unpair)
        XCTAssertNil(client.pairedPeer)
        discovery.endpointToPublish = try await pendingServer.start()
        await model.perform(.discover)
        await model.perform(.selectDevice(discovery.device.id))
        try await pairingEventually { client.isAwaitingApproval }
        await model.perform(.cancelPairing)
        try await pairingEventually { pendingClosed }
        XCTAssertEqual(client.state, .disconnected(nil))
        XCTAssertEqual(model.connection, .unpaired)
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testBilateralApprovalPersistsBeforeClientReadyAndPings() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        var serverApproved = false
        var serverCode: String?
        var observedClientReady = false
        var observedPing = false
        let server = try PairingTCPFixture { peer in
            serverCode = try await peer.handshake()
            let approval = try await peer.receive()
            XCTAssertEqual(approval.type, "approve")
            XCTAssertEqual(approval.value, serverCode)
            try await pairingEventually { serverApproved }
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            XCTAssertEqual(store.saved.count, 1, "Client pin must precede client-ready")
            observedClientReady = true
            try await peer.expect("ping")
            observedPing = true
            try await peer.send(.init(type: "pong"))
            try await peer.waitForClose()
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isAwaitingApproval }
        guard case .awaitingApproval(let peer, let code, false) = client.state else {
            return XCTFail("Verified proof must expose a fresh unapproved code")
        }
        XCTAssertEqual(code, serverCode)
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(peer.publicKey, server.identity.publicKey.rawRepresentation)
        XCTAssertTrue(store.saved.isEmpty)
        client.approve()
        client.approve()
        XCTAssertTrue(store.saved.isEmpty, "iPhone approval alone cannot save trust")
        guard case .awaitingApproval(_, _, true) = client.state else {
            return XCTFail("Approval must return immediately and leave cancel available")
        }
        serverApproved = true
        try await pairingEventually { observedClientReady && observedPing && client.isConnected }
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(client.pairedPeer, store.saved.first)
        XCTAssertTrue(server.errors.isEmpty)
        client.disconnect()
        XCTAssertEqual(client.state, .disconnected(store.saved.first))
        XCTAssertEqual(try store.peers().count, 1)
    }

    func testEarlyReadyWithoutLocalApprovalNeverWritesTrust() async throws {
        try await assertRejected { peer in
            _ = try await peer.handshake()
            try await peer.send(.init(type: "ready"))
        }
    }

    func testInvalidProofNeverExposesCodeOrTrust() async throws {
        try await assertRejected(expectCode: false) { peer in
            _ = try await peer.handshake(proof: .invalidSignature)
        }
    }

    func testReadyInPlaceOfProofNeverExposesCodeOrTrust() async throws {
        try await assertRejected(expectCode: false) { peer in
            _ = try await peer.handshake(proof: .earlyReady)
        }
    }

    func testServerRejectTerminatesWithoutTrust() async throws {
        try await assertRejected { peer in
            _ = try await peer.handshake()
            try await peer.send(.init(type: "reject"))
        }
    }

    func testRemoteEOFDuringApprovalInvalidatesStaleApprove() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            peer.transport.cancel()
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isFailed }
        client.approve()
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertNil(client.pairedPeer)
    }

    func testCancelDuringApprovalAndDuplicateApproveDoNotSave() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        var approvalReceived = false
        var closed = false
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.expect("approve")
            approvalReceived = true
            try await peer.waitForClose()
            closed = true
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isAwaitingApproval }
        client.approve()
        client.approve()
        try await pairingEventually { approvalReceived }
        client.disconnect()
        client.approve()
        try await pairingEventually { closed }
        XCTAssertEqual(client.state, .disconnected(nil))
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(server.errors.isEmpty)
    }

    func testInitialDeadlineIncludesPartialFrame() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(
            store: store, timeouts: .init(initial: 0.1, approval: 1, idle: 1, heartbeat: 0.1)
        )
        let server = try PairingTCPFixture { peer in
            _ = try await peer.transport.receive()
            try await peer.sendRaw(Data([0, 0]))
            try await peer.waitForClose()
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isFailed }
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testApprovalDeadlineClosesPendingReader() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(
            store: store, timeouts: .init(initial: 1, approval: 0.1, idle: 1, heartbeat: 0.1)
        )
        var closed = false
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.waitForClose()
            closed = true
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isFailed && closed }
        client.approve()
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testIdleDeadlineRequiresPongNotMerelyOutboundPing() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(
            store: store, timeouts: .init(initial: 1, approval: 1, idle: 0.2, heartbeat: 0.02)
        )
        var pingCount = 0
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            _ = try await peer.receive()
            try await peer.send(.init(type: "ready"))
            _ = try await peer.receive()
            try await peer.expect("ping")
            pingCount += 1
            try await peer.waitForClose()
        }
        defer { client.disconnect(); server.stop() }
        client.onUpdate = { state in
            if case .awaitingApproval(_, _, false) = state { client.approve() }
        }
        client.connect(to: try await server.start())
        try await pairingEventually { pingCount == 1 && client.isFailed }
        XCTAssertEqual(store.saved.count, 1, "Idle disconnect preserves trust")
    }

    func testStorageFailurePreventsClientReadyAndReportsOneSidedTrust() async throws {
        let store = PairingStoreProbe()
        store.failSave = true
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        var closedWithoutReady = false
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.expect("approve")
            try await peer.send(.init(type: "ready"))
            try await peer.waitForClose()
            closedWithoutReady = true
        }
        defer { client.disconnect(); server.stop() }
        client.onUpdate = { state in
            if case .awaitingApproval(_, _, false) = state { client.approve() }
        }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isFailed && closedWithoutReady }
        XCTAssertNil(client.pairedPeer)
        XCTAssertTrue(store.saved.isEmpty)
        guard case .failed(let message) = client.state else { return XCTFail("Expected failure") }
        XCTAssertTrue(message.contains("both devices"))
        XCTAssertTrue(server.errors.isEmpty)
    }

    func testRestoredPinReconnectsWithoutApprovalOrNewStorageWrite() async throws {
        let store = PairingStoreProbe()
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake(reconnect: true)
            try await peer.expect("resume")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            try await peer.waitForClose()
        }
        let pin = server.pin(name: "Original trusted name")
        store.saved = [pin]
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        defer { client.disconnect(); server.stop() }
        try client.restoreTrust()
        XCTAssertEqual(client.pairedPeer, pin)
        client.onUpdate = { state in
            if case .awaitingApproval = state { XCTFail("Reconnect must not become new pairing") }
        }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isConnected }
        XCTAssertEqual(client.pairedPeer, pin, "Unauthenticated Bonjour labels cannot replace the stored identity")
        XCTAssertEqual(store.saveCalls, 0)
        client.disconnect()
    }

    func testMismatchedReconnectPinNeverDowngradesToPair() async throws {
        let store = PairingStoreProbe()
        let original = MacPairedDevice(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            name: "Original Mac", pairedAt: Date()
        )
        store.saved = [original]
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake(reconnect: true)
        }
        defer { client.disconnect(); server.stop() }
        var exposedCode = false
        client.onUpdate = { state in
            if case .awaitingApproval = state { exposedCode = true }
        }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isFailed }
        XCTAssertFalse(exposedCode)
        XCTAssertEqual(server.acceptedCount, 1)
        XCTAssertEqual(store.saved, [original])
        XCTAssertEqual(store.saveCalls, 0)
    }

    func testRemoteLostTrustNeverDowngradesReconnect() async throws {
        let store = PairingStoreProbe()
        let server = try PairingTCPFixture { peer in
            let commit = try await peer.transport.receive()
            XCTAssertEqual(commit.mode, "reconnect")
            peer.transport.cancel()
        }
        store.saved = [server.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isFailed }
        XCTAssertEqual(server.acceptedCount, 1)
        XCTAssertEqual(store.saved.count, 1)
        guard case .failed(let message) = client.state else { return XCTFail("Expected failure") }
        XCTAssertTrue(message.contains("unpair on both devices"))
    }

    func testUnpairBeforeServerKeyKnownCancelsGeneration() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        var accepted = false
        var closed = false
        let server = try PairingTCPFixture { peer in
            _ = try await peer.transport.receive()
            accepted = true
            try await peer.waitForClose()
            closed = true
        }
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { accepted }
        try client.unpair()
        try await pairingEventually { closed }
        XCTAssertEqual(client.state, .disconnected(nil))
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testUnpairWritesRemovalBeforeDisconnectAndFailedRemovalKeepsPin() async throws {
        let store = PairingStoreProbe()
        let server = try PairingTCPFixture { peer in
            _ = try await peer.transport.receive()
            try await peer.waitForClose()
        }
        let pin = server.pin()
        store.saved = [pin]
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        store.onRemove = { XCTAssertEqual(client.state, .connecting) }
        try client.unpair()
        XCTAssertEqual(store.removeCalls, 1)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(client.state, .disconnected(nil))
        store.saved = [pin]
        try client.restoreTrust()
        store.failRemove = true
        XCTAssertThrowsError(try client.unpair())
        XCTAssertEqual(client.pairedPeer, pin)
        XCTAssertEqual(store.saved, [pin])
        XCTAssertTrue(client.isFailed)
    }

    func testMultiplePinsAndReadFailureFailClosed() {
        let store = PairingStoreProbe()
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        store.saved = [
            .init(publicKey: key, name: "Mac A", pairedAt: Date()),
            .init(publicKey: key, name: "Mac B", pairedAt: Date())
        ]
        let client = IOSMacPairingClient(store: store)
        XCTAssertThrowsError(try client.restoreTrust())
        XCTAssertTrue(client.isFailed)
        XCTAssertNil(client.pairedPeer)
        store.saved = []
        store.failRead = true
        XCTAssertThrowsError(try client.restoreTrust())
        client.connect(to: .hostPort(host: "127.0.0.1", port: 1))
        XCTAssertTrue(client.isFailed)
        XCTAssertEqual(store.identityCalls, 0)
    }

    func testIdentityStorageFailureFailsBeforeOpeningSocket() {
        let store = PairingStoreProbe()
        store.failIdentity = true
        let client = IOSMacPairingClient(store: store)
        client.connect(to: .hostPort(host: "127.0.0.1", port: 1))
        XCTAssertTrue(client.isFailed)
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testNewConnectInvalidatesOldApprovalAndReader() async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        var oldClosed = false
        let first = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.waitForClose()
            oldClosed = true
        }
        let second = try PairingTCPFixture { peer in
            _ = try await peer.handshake()
            try await peer.expect("approve")
            try await peer.send(.init(type: "ready"))
            _ = try await peer.receive()
            try await peer.waitForClose()
        }
        defer { client.disconnect(); first.stop(); second.stop() }
        client.connect(to: try await first.start())
        try await pairingEventually { client.isAwaitingApproval }
        client.connect(to: try await second.start())
        client.approve()
        try await pairingEventually { client.isAwaitingApproval && oldClosed }
        XCTAssertTrue(store.saved.isEmpty)
        client.approve()
        try await pairingEventually { client.isConnected }
        XCTAssertEqual(store.saved.first?.publicKey, second.identity.publicKey.rawRepresentation)
    }

    func testMalformedCommitFieldsAndOversizedFramesFailClosed() async throws {
        let invalidPackets = [
            #"{"type":"commit","mode":"pair","payload":"AA==","counter":0}"#,
            #"{"type":"commit","mode":"pair","payload":"AA==","unknown":1}"#,
            #"{"type":"commit","mode":7,"payload":"AA=="}"#,
            #"{"type":"reveal","payload":"AA=="}"#,
            #"{"type":"commit","mode":"reconnect","payload":"AA=="}"#
        ]
        for json in invalidPackets {
            try await assertRejected(expectCode: false) { peer in
                _ = try await peer.transport.receive()
                try await peer.sendJSON(json)
            }
        }
        try await assertRejected(expectCode: false) { peer in
            _ = try await peer.transport.receive()
            try await peer.sendRaw(Data([0, 0, 0x10, 0x01]))
        }
    }

    func testMalformedCanonicalHelloAndWrongRoleCommitmentFailClosed() async throws {
        for mutation in [
            PairingTestPeer.HelloMutation.controlName, .trailingByte, .wrongMode, .wrongRole, .wrongCommitment
        ] {
            try await assertRejected(expectCode: false) { peer in
                _ = try await peer.handshake(helloMutation: mutation)
            }
        }
    }

    func testBadCounterNonceAndUnknownEncryptedMessageFailClosed() async throws {
        for mutation in [
            PairingTestPeer.SealedMutation.counter, .nonce, .mode, .unknownMessage, .unexpectedValue
        ] {
            try await assertRejected(approve: true) { peer in
                _ = try await peer.handshake()
                try await peer.expect("approve")
                try await peer.sendMalformed(mutation)
            }
        }
    }

    private func assertRejected(
        expectCode: Bool = true,
        approve: Bool = false,
        script: @escaping @MainActor (PairingTestPeer) async throws -> Void
    ) async throws {
        let store = PairingStoreProbe()
        let client = IOSMacPairingClient(store: store, timeouts: shortTimeouts)
        var exposedCode = false
        client.onUpdate = { state in
            if case .awaitingApproval(_, _, false) = state {
                exposedCode = true
                if approve { client.approve() }
            }
        }
        let server = try PairingTCPFixture(script: script)
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start())
        try await pairingEventually { client.isFailed }
        if !expectCode { XCTAssertFalse(exposedCode, "Never display an unverified SAS") }
        XCTAssertEqual(server.acceptedCount, 1, "Rejection must exercise a real accepted TCP connection")
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertNil(client.pairedPeer)
        XCTAssertEqual(store.saveCalls, 0)
    }
}

@MainActor
extension IOSMacPairingClient {
    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
    var isAwaitingApproval: Bool {
        if case .awaitingApproval = state { return true }
        return false
    }
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }
}

enum PairingTestError: Error { case timeout, storage, unexpectedMessage }

@MainActor
private final class PairingDiscoveryProbe: MacDiscovering {
    let device = MacConnectionModel.Device(id: "test-candidate", name: "Untrusted Bonjour label")
    var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)?
    var endpointToPublish: NWEndpoint
    private var active = false

    init(endpoint: NWEndpoint) { endpointToPublish = endpoint }
    func endpoint(for deviceID: String) -> NWEndpoint? {
        active && deviceID == device.id ? endpointToPublish : nil
    }
    func start() {
        active = true
        onUpdate?(.devices([device]))
    }
    func stop() { active = false }
}

@MainActor
func pairingEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw PairingTestError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class PairingStoreProbe: MacPairingIdentityStoring {
    let key = Curve25519.Signing.PrivateKey()
    var saved: [MacPairedDevice] = []
    var saveCalls = 0
    var removeCalls = 0
    var identityCalls = 0
    var failSave = false
    var failRead = false
    var failRemove = false
    var failIdentity = false
    var onRemove: (() -> Void)?

    func identity() throws -> Curve25519.Signing.PrivateKey {
        identityCalls += 1
        if failIdentity { throw PairingTestError.storage }
        return key
    }
    func peers() throws -> [MacPairedDevice] {
        if failRead { throw PairingTestError.storage }
        return saved
    }
    func save(_ peer: MacPairedDevice) throws {
        saveCalls += 1
        if failSave { throw PairingTestError.storage }
        saved.removeAll { $0.publicKey == peer.publicKey }
        saved.append(peer)
    }
    func remove(publicKey: Data) throws {
        removeCalls += 1
        if failRemove { throw PairingTestError.storage }
        onRemove?()
        saved.removeAll { $0.publicKey == publicKey }
    }
}

@MainActor
final class PairingTCPFixture {
    let identity: Curve25519.Signing.PrivateKey
    private let listener: NWListener
    private let script: @MainActor (PairingTestPeer) async throws -> Void
    private var peers: [PairingTestPeer] = []
    private var tasks: [Task<Void, Never>] = []
    private var ready = false
    private var startupError: (any Error)?
    private(set) var errors: [any Error] = []
    private(set) var acceptedCount = 0

    init(identity: Curve25519.Signing.PrivateKey = .init(), script: @escaping @MainActor (PairingTestPeer) async throws -> Void) throws {
        self.identity = identity
        self.script = script
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.ready = true
                case .failed(let error): self?.startupError = error
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
    }

    func start() async throws -> NWEndpoint {
        listener.start(queue: DispatchQueue(label: "transcript.test.pairing.listener"))
        try await pairingEventually { self.ready || self.startupError != nil }
        if let startupError { throw startupError }
        return .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port))
    }

    func pin(name: String = "Test Mac") -> MacPairedDevice {
        .init(publicKey: identity.publicKey.rawRepresentation, name: name, pairedAt: Date())
    }

    private func accept(_ connection: NWConnection) {
        acceptedCount += 1
        let peer = PairingTestPeer(connection: connection, identity: identity)
        peers.append(peer)
        peer.transport.start()
        tasks.append(Task { [weak self] in
            guard let self else { return }
            do { try await self.script(peer) }
            catch { self.errors.append(error) }
        })
    }

    func stop() {
        listener.cancel()
        peers.forEach { $0.transport.cancel() }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        peers.removeAll()
    }
}

@MainActor
final class PairingTestPeer {
    enum Proof { case valid, invalidSignature, earlyReady }
    enum HelloMutation { case none, controlName, trailingByte, wrongMode, wrongRole, wrongCommitment }
    enum SealedMutation { case counter, nonce, mode, unknownMessage, unexpectedValue }
    let transport: MacPairingTransport
    private let identity: Curve25519.Signing.PrivateKey
    private var cipher: MacPairingCipher?

    init(connection: NWConnection, identity: Curve25519.Signing.PrivateKey) {
        transport = MacPairingTransport(connection)
        self.identity = identity
    }

    func handshake(
        reconnect: Bool = false, proof: Proof = .valid, helloMutation: HelloMutation = .none
    ) async throws -> String {
        let clientCommit = try await transport.receive()
        guard clientCommit.mode == (reconnect ? "reconnect" : "pair"), clientCommit.counter == nil else {
            throw PairingTestError.unexpectedMessage
        }
        let committed = try clientCommit.bytes(expectedType: "commit", count: 32)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var serverBytes = try MacPairingHello(
            reconnect: reconnect, identity: identity.publicKey.rawRepresentation,
            ephemeral: ephemeral.publicKey.rawRepresentation, nonce: MacPairingCrypto.randomNonce(),
            name: "Test Mac"
        ).encoded()
        switch helloMutation {
        case .controlName: serverBytes[99] = 0x0A
        case .trailingByte: serverBytes.append(0)
        case .wrongMode: serverBytes[0] = reconnect ? 0 : 1
        default: break
        }
        var serverCommit = MacPairingCrypto.commitment(
            role: helloMutation == .wrongRole ? "client" : "server", hello: serverBytes
        )
        if helloMutation == .wrongCommitment { serverCommit[0] ^= 1 }
        try await transport.send(.init(
            type: "commit", payload: serverCommit.base64EncodedString(),
            mode: reconnect ? "reconnect" : "pair"
        ))
        let reveal = try await transport.receive()
        let clientBytes = try reveal.bytes(expectedType: "reveal")
        let client = try MacPairingHello(data: clientBytes)
        guard client.reconnect == reconnect,
              MacPairingCrypto.commitment(role: "client", hello: clientBytes) == committed else {
            throw PairingTestError.unexpectedMessage
        }
        try await transport.send(.init(type: "reveal", payload: serverBytes.base64EncodedString()))
        let transcript = MacPairingCrypto.transcript(client: clientBytes, server: serverBytes)
        cipher = MacPairingCipher(
            secret: try ephemeral.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: client.ephemeral)
            ), transcript: transcript, server: true
        )
        let clientProof = try await receive()
        guard clientProof.type == "auth", let value = clientProof.value,
              let signature = Data(base64Encoded: value),
              try Curve25519.Signing.PublicKey(rawRepresentation: client.identity).isValidSignature(
                signature, for: MacPairingCrypto.signatureInput(role: "client", transcript: transcript)
              ) else { throw PairingTestError.unexpectedMessage }
        if proof == .earlyReady {
            try await send(.init(type: "ready"))
        } else {
            let signingKey = proof == .invalidSignature ? Curve25519.Signing.PrivateKey() : identity
            let signature = try signingKey.signature(
                for: MacPairingCrypto.signatureInput(role: "server", transcript: transcript)
            )
            try await send(.init(type: "auth", value: signature.base64EncodedString()))
        }
        return try XCTUnwrap(cipher?.code)
    }

    func receive() async throws -> MacPairingMessage {
        let frame = try await transport.receive()
        var cipher = try XCTUnwrap(cipher)
        let message = try cipher.open(frame)
        self.cipher = cipher
        return message
    }

    func expect(_ type: String) async throws {
        let message = try await receive()
        XCTAssertEqual(message.type, type)
        guard message.type == type else { throw PairingTestError.unexpectedMessage }
    }

    func send(_ message: MacPairingMessage) async throws {
        var cipher = try XCTUnwrap(cipher)
        let frame = try cipher.seal(message)
        self.cipher = cipher
        try await transport.send(frame)
    }

    func sendMalformed(_ mutation: SealedMutation) async throws {
        var cipher = try XCTUnwrap(cipher)
        let message = MacPairingMessage(
            type: mutation == .unknownMessage ? "unsupported" : "ready",
            value: mutation == .unexpectedValue ? "unexpected" : nil
        )
        var frame = try cipher.seal(message)
        self.cipher = cipher
        switch mutation {
        case .counter: frame.counter = 99
        case .mode: frame.mode = "pair"
        case .nonce:
            var bytes = try frame.bytes(expectedType: "sealed")
            bytes[0] ^= 1
            frame.payload = bytes.base64EncodedString()
        default: break
        }
        try await transport.send(frame)
    }

    func sendJSON(_ json: String) async throws {
        let data = Data(json.utf8)
        var length = UInt32(data.count).bigEndian
        try await sendRaw(withUnsafeBytes(of: &length) { Data($0) } + data)
    }

    func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            transport.connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func waitForClose() async throws {
        do {
            _ = try await transport.receive()
        } catch {
            return
        }
        throw PairingTestError.unexpectedMessage
    }
}
