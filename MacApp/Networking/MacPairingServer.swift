import CryptoKit
import Foundation
import Network
import Observation
import OSLog

enum MacAuthenticatedConnectionError: String, LocalizedError {
    case closed, idleTimeout, unsupportedRequest

    var errorDescription: String? {
        switch self {
        case .closed:
            String(localized: "The iPhone connection ended. Reconnect from your iPhone. Your saved pairing is unchanged.")
        case .idleTimeout:
            String(localized: "The iPhone stopped sending connection heartbeats. Open Transcript on your iPhone to reconnect. Your saved pairing is unchanged.")
        case .unsupportedRequest:
            String(localized: "The iPhone requested an unavailable feature. Enable meeting receiving on this Mac, reconnect, and retry. Your saved pairing is unchanged.")
        }
    }
}

@MainActor
@Observable
final class MacPairingServer {
    typealias MeetingCopySessionFactory = @MainActor (MacPairedDevice, Data) -> MacMeetingCopySession?
    enum State: Equatable {
        case idle, negotiating, awaitingConfirmation, connected
        case failed(String)
    }

    struct Confirmation: Equatable {
        let id = UUID()
        let name: String
        let code: String
    }

    private(set) var state: State = .idle
    private(set) var confirmation: Confirmation?
    private(set) var connectedPeer: MacPairedDevice?
    private(set) var peers: [MacPairedDevice] = []
    private(set) var allowsNewPairing = false
    private(set) var localApproved = false
    @ObservationIgnored var makeMeetingCopySession: MeetingCopySessionFactory?
    @ObservationIgnored private let store: any MacPairingIdentityStoring
    @ObservationIgnored private var session: MacPairingSession?
    @ObservationIgnored private var enableTask: Task<Void, Never>?
    @ObservationIgnored private var attemptsLeft = 0
    @ObservationIgnored private let handshakeTimeout: Duration
    @ObservationIgnored private let confirmationTimeout: Duration
    @ObservationIgnored private let idleTimeout: Duration
    private let name: String

    init(
        name: String,
        store: any MacPairingIdentityStoring = MacPairingKeychainStore(),
        handshakeTimeout: Duration = .seconds(10),
        confirmationTimeout: Duration = .seconds(60),
        idleTimeout: Duration = .seconds(120)
    ) {
        self.name = name
        self.store = store
        self.handshakeTimeout = handshakeTimeout
        self.confirmationTimeout = confirmationTimeout
        self.idleTimeout = idleTimeout
        do { peers = try store.peers() }
        catch { state = .failed(error.localizedDescription) }
    }

    isolated deinit {
        enableTask?.cancel()
        session?.close()
    }

    func enablePairing() {
        guard session == nil else { return }
        allowsNewPairing = true
        attemptsLeft = 5
        state = .idle
        enableTask?.cancel()
        enableTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.allowsNewPairing = false
        }
    }

    func accept(_ connection: NWConnection) {
        guard session == nil else { connection.cancel(); return }
        localApproved = false
        state = .negotiating
        let session = MacPairingSession(
            connection: connection, name: name, store: store,
            handshakeTimeout: handshakeTimeout, confirmationTimeout: confirmationTimeout,
            idleTimeout: idleTimeout,
            makeMeetingCopySession: makeMeetingCopySession,
            allowPairing: { [weak self] in
                guard let self, self.allowsNewPairing, self.attemptsLeft > 0 else { return false }
                self.attemptsLeft -= 1
                if self.attemptsLeft == 0 { self.allowsNewPairing = false }
                return true
            },
            onConfirmation: { [weak self] confirmation in
                self?.confirmation = confirmation
                self?.state = .awaitingConfirmation
            },
            onConnected: { [weak self] peer in
                self?.confirmation = nil
                self?.connectedPeer = peer
                self?.state = .connected
                self?.allowsNewPairing = false
                self?.reloadPeers()
            },
            onEnd: { [weak self] error in
                self?.session = nil
                self?.confirmation = nil
                self?.connectedPeer = nil
                self?.state = error.map { .failed($0.localizedDescription) } ?? .idle
                self?.reloadPeers()
            }
        )
        self.session = session
        session.start()
    }

    func confirm(requestID: UUID) {
        guard confirmation?.id == requestID else { return }
        localApproved = true
        session?.approve()
    }
    func reject(requestID: UUID) {
        guard confirmation?.id == requestID else { return }
        session?.reject()
    }

    func disconnect() {
        session?.close()
        session = nil
        confirmation = nil
        connectedPeer = nil
        localApproved = false
        state = .idle
    }

    func disableNewPairing() {
        enableTask?.cancel()
        allowsNewPairing = false
        attemptsLeft = 0
    }

    func isConnectedAndTrusted(_ peer: MacPairedDevice) throws -> Bool {
        guard state == .connected, connectedPeer?.publicKey == peer.publicKey else { return false }
        return try store.peers().contains { $0.publicKey == peer.publicKey }
    }

    func stop() {
        disableNewPairing()
        disconnect()
    }

    func unpair(_ peer: MacPairedDevice) {
        do {
            try store.remove(publicKey: peer.publicKey)
            // Also close an in-flight handshake so it cannot restore a just-deleted pin.
            disconnect()
            reloadPeers()
        } catch { state = .failed(error.localizedDescription) }
    }

    private func reloadPeers() {
        do { peers = try store.peers() }
        catch { state = .failed(error.localizedDescription) }
    }
}

@MainActor
private final class MacPairingSession {
    private let transport: MacPairingTransport
    private let name: String
    private let store: any MacPairingIdentityStoring
    private let handshakeTimeout: Duration
    private let confirmationTimeout: Duration
    private let idleTimeout: Duration
    private let allowPairing: @MainActor () -> Bool
    private let onConfirmation: @MainActor (MacPairingServer.Confirmation) -> Void
    private let onConnected: @MainActor (MacPairedDevice) -> Void
    private let onEnd: @MainActor ((any Error)?) -> Void
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var cipher: MacPairingCipher?
    private var ended = false
    private var localApproved = false
    private var presentingConfirmation = false
    private var approvalWaiter: CheckedContinuation<Bool, Never>?
    private var readyRead: Task<MacPairingMessage, any Error>?
    private var mayReceiveReady = false
    private var authenticated = false
    private let makeMeetingCopySession: MacPairingServer.MeetingCopySessionFactory?
    private var meetingCopySession: MacMeetingCopySession?
    private let logger = Logger(subsystem: "com.transcript.mac", category: "PairingSession")

    init(
        connection: NWConnection, name: String, store: any MacPairingIdentityStoring,
        handshakeTimeout: Duration, confirmationTimeout: Duration, idleTimeout: Duration,
        makeMeetingCopySession: MacPairingServer.MeetingCopySessionFactory?,
        allowPairing: @escaping @MainActor () -> Bool,
        onConfirmation: @escaping @MainActor (MacPairingServer.Confirmation) -> Void,
        onConnected: @escaping @MainActor (MacPairedDevice) -> Void,
        onEnd: @escaping @MainActor ((any Error)?) -> Void
    ) {
        transport = MacPairingTransport(connection)
        self.name = name
        self.store = store
        self.handshakeTimeout = handshakeTimeout
        self.confirmationTimeout = confirmationTimeout
        self.idleTimeout = idleTimeout
        self.makeMeetingCopySession = makeMeetingCopySession
        self.allowPairing = allowPairing
        self.onConfirmation = onConfirmation
        self.onConnected = onConnected
        self.onEnd = onEnd
    }

    func start() {
        logger.info("Incoming connection accepted; awaiting identity verification.")
        transport.start()
        setDeadline(handshakeTimeout)
        work = Task { [weak self] in
            guard let self else { return }
            do { try await run() }
            catch {
                if authenticated {
                    finish(error as? MacAuthenticatedConnectionError ?? .closed)
                } else {
                    finish(error)
                }
            }
        }
    }

    func approve() {
        guard !ended, presentingConfirmation else { return }
        localApproved = true
        approvalWaiter?.resume(returning: true)
        approvalWaiter = nil
    }

    func reject() {
        guard !ended, presentingConfirmation else { return }
        // Closing immediately also wakes a stalled peer read; rejection never persists trust.
        finish(MacPairingError.rejected)
    }

    func close() { finish(nil) }

    private func finish(_ error: (any Error)?) {
        guard !ended else { return }
        ended = true
        if let error {
            let reason = (error as? MacAuthenticatedConnectionError)?.rawValue ?? "handshakeFailure"
            logger.error("Connection ended: authenticated=\(self.authenticated), reason=\(reason, privacy: .public)")
        } else {
            logger.info("Connection closed locally: authenticated=\(self.authenticated)")
        }
        deadline?.cancel()
        work?.cancel()
        meetingCopySession?.cancel()
        meetingCopySession = nil
        readyRead?.cancel()
        approvalWaiter?.resume(returning: false)
        approvalWaiter = nil
        transport.cancel()
        cipher = nil
        onEnd(error)
    }

    private func setDeadline(_ duration: Duration) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) }
            catch { return }
            guard let self else { return }
            if self.authenticated { self.finish(MacAuthenticatedConnectionError.idleTimeout) }
            else { self.finish(MacPairingError.timedOut) }
        }
    }

    private func ensureActive() throws {
        guard !ended, !Task.isCancelled else { throw MacPairingError.rejected }
    }

    private func send(_ message: MacPairingMessage) async throws {
        try ensureActive()
        guard let frame = try cipher?.seal(message) else { throw MacPairingError.invalidMessage }
        try await transport.send(frame)
        try ensureActive()
    }

    private func receive() async throws -> MacPairingMessage {
        let frame = try await transport.receive()
        try ensureActive()
        guard let message = try cipher?.open(frame) else { throw MacPairingError.invalidMessage }
        if message.type == "reject" { throw MacPairingError.rejected }
        return message
    }

    private func monitorPendingConfirmation() {
        // Keep this sole read alive across the local UI wait and the final ready exchange.
        readyRead = Task { [self] in
            do {
                let message = try await receive()
                guard mayReceiveReady, message.type == "ready", message.value == nil else {
                    throw MacPairingError.invalidMessage
                }
                return message
            } catch {
                finish(error)
                throw error
            }
        }
    }

    private func run() async throws {
        let commit = try await transport.receive()
        try ensureActive()
        guard commit.counter == nil, let mode = commit.mode, ["pair", "reconnect"].contains(mode) else {
            throw MacPairingError.invalidMessage
        }
        let clientCommitment = try commit.bytes(expectedType: "commit", count: 32)
        let reconnect = mode == "reconnect"
        guard reconnect || allowPairing() else { throw MacPairingError.unavailable }
        let identity = try store.identity()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let serverHello = try MacPairingHello(
            reconnect: reconnect, identity: identity.publicKey.rawRepresentation,
            ephemeral: ephemeral.publicKey.rawRepresentation, nonce: MacPairingCrypto.randomNonce(), name: name
        ).encoded()
        try await transport.send(MacPairingFrame(
            type: "commit",
            payload: MacPairingCrypto.commitment(role: "server", hello: serverHello).base64EncodedString(),
            mode: mode
        ))
        let reveal = try await transport.receive()
        try ensureActive()
        guard reveal.mode == nil, reveal.counter == nil else { throw MacPairingError.invalidMessage }
        let clientHello = try reveal.bytes(expectedType: "reveal")
        guard MacPairingCrypto.constantTimeEqual(
            clientCommitment, MacPairingCrypto.commitment(role: "client", hello: clientHello)
        ) else { throw MacPairingError.invalidMessage }
        let peer = try MacPairingHello(data: clientHello)
        guard peer.reconnect == reconnect, peer.identity != identity.publicKey.rawRepresentation else {
            throw MacPairingError.invalidMessage
        }
        let storedPeer = try store.peers().first { $0.publicKey == peer.identity }
        guard !reconnect || storedPeer != nil else { throw MacPairingError.identityMismatch }
        try await transport.send(MacPairingFrame(type: "reveal", payload: serverHello.base64EncodedString()))
        let transcript = MacPairingCrypto.transcript(client: clientHello, server: serverHello)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.ephemeral)
        )
        cipher = MacPairingCipher(secret: secret, transcript: transcript, server: true)
        let proof = try await receive()
        guard proof.type == "auth", let encodedSignature = proof.value,
              let signature = Data(base64Encoded: encodedSignature),
              try Curve25519.Signing.PublicKey(rawRepresentation: peer.identity).isValidSignature(
                signature, for: MacPairingCrypto.signatureInput(role: "client", transcript: transcript)
              ) else { throw MacPairingError.identityMismatch }
        try await send(MacPairingMessage(
            type: "auth",
            value: identity.signature(for: MacPairingCrypto.signatureInput(role: "server", transcript: transcript))
                .base64EncodedString()
        ))
        if !reconnect {
            guard let code = cipher?.code else { throw MacPairingError.invalidMessage }
            presentingConfirmation = true
            setDeadline(confirmationTimeout)
            onConfirmation(.init(name: peer.name, code: code))
            let approval = try await receive()
            guard approval.type == "approve", approval.value == code else { throw MacPairingError.rejected }
            monitorPendingConfirmation()
            if !localApproved {
                let approved = await withCheckedContinuation { approvalWaiter = $0 }
                guard approved else { throw MacPairingError.rejected }
            }
            try ensureActive()
        } else {
            let resume = try await receive()
            guard resume.type == "resume", resume.value == nil else { throw MacPairingError.invalidMessage }
        }
        presentingConfirmation = false
        let trusted = storedPeer ?? MacPairedDevice(publicKey: peer.identity, name: peer.name, pairedAt: Date())
        if !reconnect { try store.save(trusted) }
        mayReceiveReady = true
        try await send(.init(type: "ready"))
        let ready: MacPairingMessage
        if let readyRead {
            ready = try await readyRead.value
            self.readyRead = nil
        } else {
            ready = try await receive()
        }
        guard ready.type == "ready", ready.value == nil else { throw MacPairingError.invalidMessage }
        try ensureActive()
        authenticated = true
        logger.info("Authenticated connection established.")
        onConnected(trusted)
        meetingCopySession = makeMeetingCopySession?(trusted, identity.publicKey.rawRepresentation)
        while true {
            setDeadline(idleTimeout)
            let message = try await receive()
            if message.type == "ping", message.value == nil {
                try await send(.init(type: "pong"))
            } else if message.type == MeetingCopyWire.innerType, let meetingCopySession {
                let response = try await meetingCopySession.handle(message)
                try await send(response)
            } else {
                throw MacAuthenticatedConnectionError.unsupportedRequest
            }
        }
    }
}
