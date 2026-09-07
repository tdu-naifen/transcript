import CryptoKit
import Foundation
import Network
import Observation
import OSLog
import TranscriptCore

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
    // The frozen v1 iPhone sends a heartbeat every 30 seconds.
    static let defaultIdleTimeout: Duration = .seconds(45)
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
    private(set) var automaticSyncProblem: String?
    private(set) var automaticSyncSending = false
    private(set) var automaticSyncProgress: AutomaticSyncResourceChannel.Progress?
    @ObservationIgnored var makeMeetingCopySession: MeetingCopySessionFactory?
    @ObservationIgnored var makeAutomaticSyncChannel: AutomaticSyncChannel.Factory?
    @ObservationIgnored var makeAutomaticSyncResourceChannel: AutomaticSyncResourceChannel.Factory?
    @ObservationIgnored private var automaticSyncRepository: AutomaticSyncRepository?
    @ObservationIgnored private var onAutomaticAudioImported: (@MainActor (AutomaticSyncResourceChannel.AudioImport) async throws -> Void)?
    @ObservationIgnored private var revokingTrust = false
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
        idleTimeout: Duration = MacPairingServer.defaultIdleTimeout
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

    var isConnected: Bool { state == .connected && connectedPeer != nil }
    var peerAllowsAutomaticSyncVoiceprints: Bool { session?.peerAllowsVoiceprints == true }

    func installAutomaticSync(
        database: AppDatabase, audioDirectory: URL? = nil,
        onAudioImported: @escaping @MainActor (AutomaticSyncResourceChannel.AudioImport) async throws -> Void = { _ in }
    ) {
        guard automaticSyncRepository == nil else { return }
        let repository = AutomaticSyncRepository(database)
        automaticSyncRepository = repository
        onAutomaticAudioImported = onAudioImported
        makeAutomaticSyncChannel = { [weak self] peer, send in
            guard let self else { return nil }
            automaticSyncProblem = nil
            return AutomaticSyncChannel(
                storage: .repository(repository, peer: peer, isTrusted: { [weak self] in
                    try self?.isConnectedAndTrusted(peer) ?? false
                }),
                send: send, onFailure: { [weak self] in self?.disconnect() },
                onProblem: { [weak self] error in self?.automaticSyncProblem = String(describing: error) },
                onSending: { [weak self] in self?.automaticSyncSending = $0 }
            )
        }
        if let audioDirectory {
            makeAutomaticSyncResourceChannel = { [weak self] peer, send in
                guard let self else { return nil }
                return AutomaticSyncResourceChannel(
                    storage: .repository(database: database, peer: peer, audioDirectory: audioDirectory, isTrusted: { [weak self] in
                        try self?.isConnectedAndTrusted(peer) ?? false
                    }, peerAllowsVoiceprints: { [weak self] in
                        self?.peerAllowsAutomaticSyncVoiceprints == true
                    }, onAudioImported: onAudioImported),
                    send: send, onFailure: { [weak self] in self?.disconnect() },
                    onProblem: { [weak self] error in self?.automaticSyncProblem = String(describing: error) },
                    onProgress: { [weak self] in self?.automaticSyncProgress = $0 }
                )
            }
        }
    }

    func replayAutomaticAudioImports() async throws {
        guard let repository = automaticSyncRepository, let onAutomaticAudioImported else { return }
        for imported in try await repository.verifiedAudioImports() {
            guard !revokingTrust,
                  try store.peers().contains(where: { AutomaticSyncChannel.peerID($0) == imported.peerID }) else { continue }
            let status = try await repository.status(peerID: imported.peerID)
            guard status.enabled, !revokingTrust,
                  try store.peers().contains(where: { AutomaticSyncChannel.peerID($0) == imported.peerID }) else { continue }
            try await onAutomaticAudioImported(.init(
                meetingID: imported.meetingID, inputRevision: imported.audioSHA256,
                peerID: imported.peerID, operationID: imported.operationID
            ))
        }
    }

    func automaticSyncStatus(for peer: MacPairedDevice) async throws -> AutomaticSyncRepository.Status? {
        try await automaticSyncRepository?.status(peerID: AutomaticSyncChannel.peerID(peer))
    }

    func setAutomaticSyncEnabled(_ enabled: Bool, for peer: MacPairedDevice) async throws {
        guard !revokingTrust, let repository = automaticSyncRepository,
              try store.peers().contains(where: { $0.publicKey == peer.publicKey }) else {
            throw MacPairingError.identityMismatch
        }
        disconnect()
        try await repository.configure(peerID: AutomaticSyncChannel.peerID(peer), enabled: enabled)
    }

    func setVoiceprintSyncConsent(_ consent: AutomaticSyncRepository.Wire.Consent, for peer: MacPairedDevice) async throws {
        guard !revokingTrust, let repository = automaticSyncRepository,
              try store.peers().contains(where: { $0.publicKey == peer.publicKey }) else {
            throw MacPairingError.identityMismatch
        }
        disconnect()
        try await repository.setVoiceprintConsent(peerID: AutomaticSyncChannel.peerID(peer), state: consent)
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
        guard session == nil, !revokingTrust else { connection.cancel(); return }
        localApproved = false
        state = .negotiating
        let session = MacPairingSession(
            connection: connection, name: name, store: store,
            handshakeTimeout: handshakeTimeout, confirmationTimeout: confirmationTimeout,
            idleTimeout: idleTimeout,
            makeMeetingCopySession: makeMeetingCopySession,
            makeAutomaticSyncChannel: makeAutomaticSyncChannel,
            makeAutomaticSyncResourceChannel: makeAutomaticSyncResourceChannel,
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

    func unpair(_ peer: MacPairedDevice) async {
        guard !revokingTrust else { return }
        revokingTrust = true
        defer { revokingTrust = false }
        disableNewPairing()
        disconnect()
        do {
            if let repository = automaticSyncRepository {
                let id = AutomaticSyncChannel.peerID(peer)
                try await repository.configure(peerID: id, enabled: false)
                try await repository.setVoiceprintConsent(peerID: id, state: .revoked)
            }
            try store.remove(publicKey: peer.publicKey)
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
    private let diagnosticID = UUID()
    private var lastBoundary = "accepted"
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
    private let makeAutomaticSyncChannel: AutomaticSyncChannel.Factory?
    private let makeAutomaticSyncResourceChannel: AutomaticSyncResourceChannel.Factory?
    private var automaticSync: AutomaticSyncChannel?
    private var automaticSyncResources: AutomaticSyncResourceChannel?
    var peerAllowsVoiceprints: Bool { automaticSync?.peerVoiceprintsAllowed == true }
    private var sendTail: Task<Void, any Error>?
    private let logger = Logger(subsystem: "com.transcript.mac", category: "PairingSession")

    init(
        connection: NWConnection, name: String, store: any MacPairingIdentityStoring,
        handshakeTimeout: Duration, confirmationTimeout: Duration, idleTimeout: Duration,
        makeMeetingCopySession: MacPairingServer.MeetingCopySessionFactory?,
        makeAutomaticSyncChannel: AutomaticSyncChannel.Factory?,
        makeAutomaticSyncResourceChannel: AutomaticSyncResourceChannel.Factory?,
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
        self.makeAutomaticSyncChannel = makeAutomaticSyncChannel
        self.makeAutomaticSyncResourceChannel = makeAutomaticSyncResourceChannel
        self.allowPairing = allowPairing
        self.onConfirmation = onConfirmation
        self.onConnected = onConnected
        self.onEnd = onEnd
    }

    func start() {
        logger.info("Incoming connection accepted; awaiting identity verification.")
        logPath(event: "accepted")
        transport.connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.ended else { return }
                switch state {
                case .ready:
                    self.logPath(event: "transport-ready")
                case .waiting(let error):
                    self.logPath(event: "waiting-\(Self.errorCode(error))")
                    if self.authenticated { self.finish(MacAuthenticatedConnectionError.closed) }
                    else { self.finish(MacPairingError.unavailable) }
                case .failed, .cancelled:
                    if self.authenticated { self.finish(MacAuthenticatedConnectionError.closed) }
                    else { self.finish(MacPairingError.unavailable) }
                default:
                    break
                }
            }
        }
        transport.connection.viabilityUpdateHandler = { [weak self] viable in
            guard !viable else { return }
            Task { @MainActor [weak self] in
                guard let self, self.authenticated, !self.ended else { return }
                self.finish(MacAuthenticatedConnectionError.closed)
            }
        }
        self.transport.connection.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.ended else { return }
                self.logPath(event: "path-updated")
            }
        }
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
            logger.error("Connection ended: authenticated=\(self.authenticated), reason=\(reason, privacy: .public) lastBoundary=\(self.lastBoundary, privacy: .public) generation=\(self.diagnosticID.uuidString, privacy: .public)")
        } else {
            logger.info("Connection closed locally: authenticated=\(self.authenticated)")
        }
        deadline?.cancel()
        work?.cancel()
        meetingCopySession?.cancel()
        meetingCopySession = nil
        automaticSync?.stop()
        automaticSync = nil
        automaticSyncResources?.stop()
        automaticSyncResources = nil
        sendTail?.cancel()
        readyRead?.cancel()
        approvalWaiter?.resume(returning: false)
        approvalWaiter = nil
        transport.connection.stateUpdateHandler = nil
        transport.connection.viabilityUpdateHandler = nil
        transport.connection.pathUpdateHandler = nil
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
        let previous = sendTail
        let task = Task { [self] in
            try await previous?.value
            try ensureActive()
            try await transport.send(frame)
        }
        sendTail = task
        try await task.value
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
        recordBoundary("commitmentReceived")
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
        recordBoundary("identityVerified")
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
        recordBoundary("authenticated")
        logger.info("Authenticated connection established.")
        onConnected(trusted)
        meetingCopySession = makeMeetingCopySession?(trusted, identity.publicKey.rawRepresentation)
        automaticSync = makeAutomaticSyncChannel?(trusted, { [weak self] message in
            guard let self else { throw CancellationError() }
            try await self.send(message)
        })
        automaticSyncResources = makeAutomaticSyncResourceChannel?(trusted, { [weak self] message in
            guard let self else { throw CancellationError() }
            try await self.send(message)
        })
        while true {
            setDeadline(idleTimeout)
            let message = try await receive()
            if message.type == "ping", message.value == nil {
                try await send(.init(type: "pong"))
            } else if message.type == "automaticSyncResources.v1", let automaticSyncResources {
                try await automaticSyncResources.handle(message)
            } else if message.type == "automaticSync.v1", let automaticSync {
                try await automaticSync.handle(message)
            } else if message.type == MeetingCopyWire.innerType, let meetingCopySession {
                let response = try await meetingCopySession.handle(message)
                try await send(response)
                recordBoundary("meetingCopyReplySent")
            } else {
                throw MacAuthenticatedConnectionError.unsupportedRequest
            }
        }

    }

    private func recordBoundary(_ boundary: String) {
        lastBoundary = boundary
        logPath(event: "boundary-\(boundary)")
    }

    private func logPath(event: String) {
        let path = transport.connection.currentPath
        let interfaces = path?.availableInterfaces.map {
            "\($0.name):\($0.type):typeUsed=\(path?.usesInterfaceType($0.type) == true)"
        }.sorted().joined(separator: ",") ?? "unknown"
        let status = path.map { String(describing: $0.status) } ?? "unknown"
        // Endpoint hashes correlate a route within logs without exposing names or addresses.
        // Interface type is evidence of the selected path, not proof that USB carried data.
        logger.info("event=\(event, privacy: .public) generation=\(self.diagnosticID.uuidString, privacy: .public) endpoint=\(String(describing: self.transport.connection.endpoint), privacy: .private(mask: .hash)) path=\(status, privacy: .public) interfaces=\(interfaces, privacy: .public)")
    }

    private static func errorCode(_ error: NWError) -> String {
        switch error {
        case .posix(let code): "posix-\(code.rawValue)"
        case .dns(let code): "dns-\(code)"
        case .tls(let code): "tls-\(code)"
        default: "other"
        }
    }
}
