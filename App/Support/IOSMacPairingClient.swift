import CryptoKit
import Foundation
import Network

@MainActor
final class IOSMacPairingClient {
    enum State: Equatable {
        case idle
        case connecting
        case awaitingApproval(peer: MacPairedDevice, code: String, approvedLocally: Bool)
        case connected(MacPairedDevice)
        case disconnected(MacPairedDevice?)
        case failed(message: String)
    }

    struct Timeouts {
        var initial: TimeInterval = 10
        var approval: TimeInterval = 60
        var idle: TimeInterval = 120
        var heartbeat: TimeInterval = 30
    }

    private enum ClientError: LocalizedError {
        case invalidTrust, storage

        var errorDescription: String? {
            switch self {
            case .invalidTrust:
                return "Saved Mac trust is invalid or contains multiple Macs. Resolve secure storage before pairing."
            case .storage:
                return "Secure identity storage is unavailable. Check device access and try again."
            }
        }
    }

    @MainActor
    private final class Session {
        let id = UUID()
        let transport: MacPairingTransport
        let expectedPeer: MacPairedDevice?
        var cipher: MacPairingCipher?
        var peer: MacPairedDevice?
        var approvedLocally = false
        var waitingForReady = false
        var connected = false
        var awaitingPong = false
        var serverReady = false
        var reader: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var heartbeat: Task<Void, Never>?
        var sendTail: Task<Void, any Error>?
        var probeAllowed = false
        var transferAccepted = false
        var pendingRequest: MeetingCopyWire.Message?
        var reply: CheckedContinuation<MeetingCopyWire.Message, any Error>?
        var requestDeadline: Task<Void, Never>?

        init(transport: MacPairingTransport, expectedPeer: MacPairedDevice?) {
            self.transport = transport
            self.expectedPeer = expectedPeer
        }

        func cancel(transferError: MeetingCopyProblem) {
            transport.cancel()
            reader?.cancel()
            deadline?.cancel()
            heartbeat?.cancel()
            sendTail?.cancel()
            requestDeadline?.cancel()
            let reply = reply
            self.reply = nil
            pendingRequest = nil
            reply?.resume(throwing: transferError)
        }
    }

    private let store: any MacPairingIdentityStoring
    private let name: String
    private let timeouts: Timeouts
    private var session: Session?
    private(set) var pairedPeer: MacPairedDevice?
    private(set) var state: State = .idle
    var onUpdate: ((State) -> Void)?
    var onTransferReadiness: ((Bool) -> Void)?
    var supportsMeetingTransfer: Bool { session?.transferAccepted == true }
    var transferSessionID: UUID? { supportsMeetingTransfer ? session?.id : nil }
    var canProbeMeetingTransfer: Bool { session?.connected == true && session?.probeAllowed == true }

    init(store: any MacPairingIdentityStoring, name: String = "iPhone", timeouts: Timeouts = .init()) {
        self.store = store
        self.name = name
        self.timeouts = timeouts
    }

    func restoreTrust() throws {
        do {
            pairedPeer = try storedPeer()
        } catch {
            stopSession()
            publish(.failed(message: message(for: error)))
            throw error
        }
    }

    func connect(to endpoint: NWEndpoint, allowMeetingCopyProbe: Bool = false) {
        stopSession()
        do {
            pairedPeer = try storedPeer()
            let identity: Curve25519.Signing.PrivateKey
            do { identity = try store.identity() }
            catch { throw ClientError.storage }
            guard [timeouts.initial, timeouts.approval, timeouts.idle, timeouts.heartbeat]
                .allSatisfy({ $0.isFinite && $0 > 0 }),
                timeouts.heartbeat < timeouts.idle else { throw MacPairingError.unavailable }
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let next = Session(
                transport: MacPairingTransport(NWConnection(to: endpoint, using: parameters)),
                expectedPeer: pairedPeer
            )
            session = next
            next.probeAllowed = allowMeetingCopyProbe
            next.transport.start()
            armDeadline(timeouts.initial, for: next)
            next.reader = Task { [weak self, weak next] in
                guard let self, let next else { return }
                do { try await self.run(next, identity: identity) }
                catch { self.fail(error, session: next) }
            }
            publish(.connecting)
        } catch {
            publish(.failed(message: message(for: error)))
        }
    }

    func approve() {
        guard let current = session, !current.approvedLocally,
              case .awaitingApproval(let peer, let code, false) = state else { return }
        current.approvedLocally = true
        current.waitingForReady = true
        do {
            _ = try enqueue(MacPairingMessage(type: "approve", value: code), on: current)
            publish(.awaitingApproval(peer: peer, code: code, approvedLocally: true))
        } catch {
            fail(error, session: current)
        }
    }

    func disconnect() {
        stopSession()
        publish(.disconnected(pairedPeer))
    }

    /// Called only by explicit Send/Retry. The untrusted endpoint hint merely permits
    /// this metadata-free probe; an authenticated response is the authorization gate.
    func negotiateMeetingCopy() async throws {
        guard canProbeMeetingTransfer else { throw MeetingCopyWire.Failure.incompatible }
        if supportsMeetingTransfer { return }
        var offer = MeetingCopyWire.Message(.capabilities)
        offer.capability = MeetingCopyWire.capability
        _ = try await exchange(offer)
        guard supportsMeetingTransfer else { throw MeetingCopyWire.Failure.incompatible }
    }

    func exchange(_ request: MeetingCopyWire.Message) async throws -> MeetingCopyWire.Message {
        guard let current = session, current.connected,
              request.type == .capabilities ? current.probeAllowed : current.transferAccepted else {
            throw MeetingCopyWire.Failure.incompatible
        }
        guard current.reply == nil else { throw MeetingCopyWire.Failure.busy }
        let inner = try MeetingCopyWire.inner(request)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                current.pendingRequest = request
                current.reply = continuation
                do {
                    _ = try enqueue(inner, on: current)
                    current.requestDeadline = Task { [weak self, weak current] in
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        guard let self, let current else { return }
                        self.fail(MacPairingError.timedOut, session: current)
                    }
                } catch { fail(error, session: current) }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak current] in
                guard let self, let current, self.session === current else { return }
                self.disconnect()
            }
        }
    }

    func unpair() throws {
        do {
            // Persist revocation before invalidating the live session, even during a reveal.
            if let peer = try storedPeer() {
                do { try store.remove(publicKey: peer.publicKey) }
                catch { throw ClientError.storage }
            }
            pairedPeer = nil
            stopSession()
            publish(.disconnected(nil))
        } catch {
            stopSession()
            publish(.failed(message: "The Mac could not be forgotten. Secure storage is unavailable; its trust has not been removed."))
            throw error
        }
    }

    private func storedPeer() throws -> MacPairedDevice? {
        let peers: [MacPairedDevice]
        do { peers = try store.peers() }
        catch { throw ClientError.storage }
        guard peers.count <= 1, peers.allSatisfy({ $0.publicKey.count == 32 }) else {
            throw ClientError.invalidTrust
        }
        return peers.first
    }

    private func run(_ current: Session, identity: Curve25519.Signing.PrivateKey) async throws {
        try requireCurrent(current)
        let reconnect = current.expectedPeer != nil
        let mode = reconnect ? "reconnect" : "pair"
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = try MacPairingHello(
            reconnect: reconnect, identity: identity.publicKey.rawRepresentation,
            ephemeral: ephemeral.publicKey.rawRepresentation,
            nonce: MacPairingCrypto.randomNonce(), name: name
        ).encoded()
        try await current.transport.send(MacPairingFrame(
            type: "commit",
            payload: MacPairingCrypto.commitment(role: "client", hello: hello).base64EncodedString(),
            mode: mode
        ))
        try requireCurrent(current)
        let commitmentFrame = try await current.transport.receive()
        try requireCurrent(current)
        guard commitmentFrame.mode == mode, commitmentFrame.counter == nil else {
            throw MacPairingError.invalidMessage
        }
        let commitment = try bytes(commitmentFrame, type: "commit", count: 32)
        try await current.transport.send(MacPairingFrame(type: "reveal", payload: hello.base64EncodedString()))
        try requireCurrent(current)
        let reveal = try await current.transport.receive()
        try requireCurrent(current)
        guard reveal.mode == nil, reveal.counter == nil else { throw MacPairingError.invalidMessage }
        let serverBytes = try bytes(reveal, type: "reveal")
        let server = try MacPairingHello(data: serverBytes)
        guard try server.encoded() == serverBytes, server.reconnect == reconnect,
              MacPairingCrypto.constantTimeEqual(
                commitment, MacPairingCrypto.commitment(role: "server", hello: serverBytes)
              ) else { throw MacPairingError.invalidMessage }
        if let expected = current.expectedPeer,
           !MacPairingCrypto.constantTimeEqual(expected.publicKey, server.identity) {
            throw MacPairingError.identityMismatch
        }
        let transcript = MacPairingCrypto.transcript(client: hello, server: serverBytes)
        current.cipher = MacPairingCipher(
            secret: try ephemeral.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: server.ephemeral)
            ),
            transcript: transcript, server: false
        )
        let signature = try identity.signature(for: MacPairingCrypto.signatureInput(role: "client", transcript: transcript))
        try await enqueue(MacPairingMessage(type: "auth", value: signature.base64EncodedString()), on: current).value
        try requireCurrent(current)
        let auth = try await receive(on: current)
        guard auth.type == "auth", let value = auth.value,
              let proof = Data(base64Encoded: value), proof.count == 64,
              proof.base64EncodedString() == value,
              try Curve25519.Signing.PublicKey(rawRepresentation: server.identity).isValidSignature(
                proof, for: MacPairingCrypto.signatureInput(role: "server", transcript: transcript)
              ) else { throw MacPairingError.invalidMessage }
        let peer = current.expectedPeer ?? MacPairedDevice(
            publicKey: server.identity, name: server.name, pairedAt: Date()
        )
        current.peer = peer
        if reconnect {
            current.waitingForReady = true
            try await enqueue(MacPairingMessage(type: "resume"), on: current).value
            try requireCurrent(current)
        } else {
            armDeadline(timeouts.approval, for: current)
            guard let code = current.cipher?.code else { throw MacPairingError.invalidMessage }
            publish(.awaitingApproval(peer: peer, code: code, approvedLocally: false))
            try requireCurrent(current)
        }

        let ready = try await receive(on: current)
        if ready.type == "reject", ready.value == nil { throw MacPairingError.rejected }
        guard ready.type == "ready", ready.value == nil, current.waitingForReady,
              reconnect || current.approvedLocally else { throw MacPairingError.invalidMessage }
        // The queued approval must finish before a trust write or client-ready send.
        try await current.sendTail?.value
        try requireCurrent(current)
        current.serverReady = true
        if !reconnect {
            do { try store.save(peer) }
            catch { throw ClientError.storage }
            pairedPeer = peer
        }
        try await enqueue(MacPairingMessage(type: "ready"), on: current).value
        try requireCurrent(current)
        current.connected = true
        armDeadline(timeouts.idle, for: current)
        startHeartbeat(for: current)
        publish(.connected(peer))
        try requireCurrent(current)
        while true {
            let message = try await receive(on: current)
            if message.type == MeetingCopyWire.innerType {
                try handleTransferReply(message, on: current)
            } else if message.type == "pong", message.value == nil, current.awaitingPong {
                current.awaitingPong = false
            } else {
                throw MacPairingError.invalidMessage
            }
            armDeadline(timeouts.idle, for: current)
        }
    }

    private func handleTransferReply(_ inner: MacPairingMessage, on current: Session) throws {
        let reply = try MeetingCopyWire.message(inner)
        guard let request = current.pendingRequest, let continuation = current.reply,
              reply.requestID == request.requestID, reply.operation == request.operation else {
            throw MacPairingError.invalidMessage
        }
        let allowed: Set<MeetingCopyWire.Kind>
        switch request.type {
        case .capabilities: allowed = [.accepted]
        case .offer: allowed = [.status, .committed, .failed]
        case .chunk: allowed = [.ack, .failed]
        case .finalize: allowed = [.committed, .failed]
        default: throw MacPairingError.invalidMessage
        }
        guard allowed.contains(reply.type) else { throw MacPairingError.invalidMessage }
        if request.type == .capabilities {
            current.transferAccepted = true
            onTransferReadiness?(true)
        }
        current.requestDeadline?.cancel()
        current.requestDeadline = nil
        current.pendingRequest = nil
        current.reply = nil
        continuation.resume(returning: reply)
    }

    private func receive(on current: Session) async throws -> MacPairingMessage {
        let frame: MacPairingFrame
        do { frame = try await current.transport.receive() }
        catch {
            // Frozen v1 transport reports EOF as invalidMessage as well. Failure to
            // read a frame is not a receiver rejection of the offered meeting.
            throw MeetingCopyProblem(code: .network)
        }
        try requireCurrent(current)
        guard frame.mode == nil, frame.counter != nil else { throw MacPairingError.invalidMessage }
        _ = try bytes(frame, type: "sealed")
        guard var cipher = current.cipher else { throw MacPairingError.invalidMessage }
        let message = try cipher.open(frame)
        current.cipher = cipher
        return message
    }

    private func bytes(_ frame: MacPairingFrame, type: String, count: Int? = nil) throws -> Data {
        let data = try frame.bytes(expectedType: type, count: count)
        guard data.base64EncodedString() == frame.payload else { throw MacPairingError.invalidMessage }
        return data
    }

    private func enqueue(_ message: MacPairingMessage, on current: Session) throws -> Task<Void, any Error> {
        try requireCurrent(current)
        guard var cipher = current.cipher else { throw MacPairingError.invalidMessage }
        let frame = try cipher.seal(message)
        guard try JSONEncoder().encode(frame).count <= MacPairingTransport.maximumFrameSize else {
            throw MeetingCopyWire.Failure.invalid
        }
        current.cipher = cipher
        let previous = current.sendTail
        let task = Task { [weak self, weak current] in
            guard let self, let current else { throw CancellationError() }
            do {
                try await previous?.value
                try self.requireCurrent(current)
                try await current.transport.send(frame)
                try self.requireCurrent(current)
            } catch {
                self.fail(error, session: current)
                throw error
            }
        }
        current.sendTail = task
        return task
    }

    private func startHeartbeat(for current: Session) {
        current.heartbeat = Task { [weak self, weak current] in
            guard let self, let current else { return }
            do {
                while true {
                    try await Task.sleep(for: .seconds(self.timeouts.heartbeat))
                    try self.requireCurrent(current)
                    if !current.awaitingPong {
                        current.awaitingPong = true
                        try await self.enqueue(MacPairingMessage(type: "ping"), on: current).value
                    }
                }
            } catch {
                if !(error is CancellationError) { self.fail(error, session: current) }
            }
        }
    }

    private func armDeadline(_ seconds: TimeInterval, for current: Session) {
        current.deadline?.cancel()
        current.deadline = Task { [weak self, weak current] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                try Task.checkCancellation()
                guard let self, let current else { return }
                self.fail(MacPairingError.timedOut, session: current)
            } catch is CancellationError {
                return
            } catch {
                guard let self, let current else { return }
                self.fail(error, session: current)
            }
        }
    }

    private func requireCurrent(_ current: Session) throws {
        guard session === current, !Task.isCancelled else { throw CancellationError() }
    }

    private func stopSession(transferError: MeetingCopyProblem = .init(code: .network)) {
        let previous = session
        session = nil
        previous?.cancel(transferError: transferError)
        onTransferReadiness?(false)
    }

    private func fail(_ error: any Error, session current: Session) {
        guard session === current else { return }
        let text: String
        let rejected: Bool
        if case .rejected? = error as? MacPairingError { rejected = true }
        else { rejected = false }
        if current.connected && current.pendingRequest != nil {
            text = "Meeting copy was not confirmed. Update Transcript on the Mac if needed, then reconnect and retry. Your saved Mac identity is unchanged."
        } else if !current.connected && (current.serverReady || (current.approvedLocally && !rejected)) {
            text = "Pairing did not finish on both devices. Unpair on both devices and explicitly pair again."
        } else if current.expectedPeer != nil {
            text = "The trusted Mac could not reconnect. Check that it is online and still trusts this iPhone. If trust was removed, unpair on both devices and explicitly pair again."
        } else {
            text = message(for: error)
        }
        stopSession(transferError: MeetingCopyProblem(error))
        publish(.failed(message: text))
    }

    private func message(for error: any Error) -> String {
        if let error = error as? ClientError {
            return error.localizedDescription
        }
        if let error = error as? MacPairingError {
            switch error {
            case .identityMismatch:
                return "This Mac does not match the saved identity. Unpair explicitly before pairing a different Mac."
            case .rejected:
                return "Pairing was rejected. Compare the codes on both devices before trying again."
            case .timedOut:
                return "The secure connection timed out. Keep both devices open and try again."
            case .keychain:
                return "Secure identity storage is unavailable. Check device access and try again."
            case .invalidMessage:
                return "The secure connection could not be verified. Check the Mac and try again."
            case .unavailable:
                return "Enable pairing on the Mac, then try again."
            }
        }
        return "The Mac connection failed. Keep both devices open and try again."
    }

    private func publish(_ state: State) {
        self.state = state
        onUpdate?(state)
    }
}
