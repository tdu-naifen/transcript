import CryptoKit
import Foundation
import GRDB
import TranscriptCore

/// Multiplexed through the pairing session's sole reader and ordered writer.
/// Repository callbacks must commit before returning an acknowledgement.
@MainActor
final class AutomaticSyncChannel {
    typealias AutomaticSyncWire = AutomaticSyncRepository.Wire
    typealias Send = @MainActor (MacPairingMessage) async throws -> Void
    typealias Factory = @MainActor (MacPairedDevice, @escaping Send) -> AutomaticSyncChannel?

    struct Storage {
        var isEnabled: @MainActor () async throws -> Bool
        var pending: @MainActor () async throws -> [AutomaticSyncWire.Operation]
        var receive: @MainActor (AutomaticSyncWire.Fragment) async throws -> String?
        var acknowledge: @MainActor (String) async throws -> Void
        var voiceprintsAllowed: @MainActor () async throws -> Bool = { false }
        var pendingWithConsent: (@MainActor (Bool) async throws -> [AutomaticSyncWire.Operation])?
        var receiveWithConsent: (@MainActor (AutomaticSyncWire.Fragment, Bool) async throws -> String?)?
        var changes: (@MainActor () -> AsyncValueObservation<Void>)?

        @MainActor static func repository(
            _ repository: AutomaticSyncRepository, peer: MacPairedDevice,
            isTrusted: @escaping @MainActor () throws -> Bool
        ) -> Self {
            let id = AutomaticSyncChannel.peerID(peer)
            return Self(
                isEnabled: {
                    guard try isTrusted() else { return false }
                    let status = try await repository.status(peerID: id)
                    return try isTrusted() && status.enabled
                },
                pending: {
                    guard try isTrusted() else { throw AutomaticSyncWire.Failure.disabled }
                    return try await repository.pending(peerID: id, limit: 64, includeBiometrics: false)
                },
                receive: {
                    guard try isTrusted() else { throw AutomaticSyncWire.Failure.disabled }
                    return try await repository.receive($0, from: id)
                },
                acknowledge: {
                    guard try isTrusted() else { throw AutomaticSyncWire.Failure.disabled }
                    try await repository.acknowledge(peerID: id, operationIDs: [$0])
                },
                voiceprintsAllowed: {
                    guard try isTrusted() else { return false }
                    let status = try await repository.status(peerID: id)
                    return try isTrusted() && status.enabled && status.voiceprints == .allowed
                },
                pendingWithConsent: { peerAllows in
                    guard try isTrusted() else { throw AutomaticSyncWire.Failure.disabled }
                    return try await repository.pending(peerID: id, limit: 64, includeBiometrics: peerAllows)
                },
                receiveWithConsent: { fragment, peerAllows in
                    guard try isTrusted() else { throw AutomaticSyncWire.Failure.disabled }
                    return try await repository.receive(fragment, from: id, includeBiometrics: peerAllows)
                },
                changes: { repository.changes() }
            )
        }
    }

    static func peerID(_ peer: MacPairedDevice) -> String {
        SHA256.hash(data: peer.publicKey).map { String(format: "%02x", $0) }.joined()
    }

    private let storage: Storage
    private let send: Send
    private let onFailure: @MainActor () -> Void
    private let onProblem: @MainActor (any Error) -> Void
    private let onSending: @MainActor (Bool) -> Void
    private var sender: Task<Void, Never>?
    private var fragmentWriter: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var acknowledgement: CheckedContinuation<Void, any Error>?
    private var pendingID: String?
    private var pendingRequestID: String?
    private var helloID: String?
    private var accepted = false
    private(set) var peerVoiceprintsAllowed = false
    private var stopped = false

    init(
        storage: Storage, send: @escaping Send, onFailure: @escaping @MainActor () -> Void,
        onProblem: @escaping @MainActor (any Error) -> Void = { _ in },
        onSending: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.storage = storage
        self.send = send
        self.onFailure = onFailure
        self.onProblem = onProblem
        self.onSending = onSending
    }

    func negotiate() async throws {
        guard !stopped, try await storage.isEnabled(), !stopped else { return }
        var hello = AutomaticSyncWire.Message(kind: .hello, capability: AutomaticSyncWire.capability)
        hello.voiceprintsAllowed = try await storage.voiceprintsAllowed()
        guard !stopped else { return }
        helloID = hello.requestID
        armDeadline()
        try await write(hello)
    }

    func handle(_ inner: MacPairingMessage) async throws {
        guard !stopped, try await storage.isEnabled(), !stopped,
              inner.type == AutomaticSyncWire.messageType,
              let value = inner.value, let bytes = value.data(using: .utf8) else {
            throw AutomaticSyncWire.Failure.disabled
        }
        let message = try AutomaticSyncWire.decode(bytes)
        switch message.kind {
        case .hello:
            guard !accepted, helloID == nil else { throw AutomaticSyncWire.Failure.invalid }
            peerVoiceprintsAllowed = message.voiceprintsAllowed
            var response = AutomaticSyncWire.Message(
                kind: .accepted, requestID: message.requestID, capability: AutomaticSyncWire.capability
            )
            response.voiceprintsAllowed = try await storage.voiceprintsAllowed()
            try await write(response)
            accepted = true
            startSender()
        case .accepted:
            guard !accepted, helloID == message.requestID else { throw AutomaticSyncWire.Failure.invalid }
            helloID = nil
            peerVoiceprintsAllowed = message.voiceprintsAllowed
            deadline?.cancel()
            accepted = true
            startSender()
        case .fragment:
            guard accepted, let fragment = message.fragment else { throw AutomaticSyncWire.Failure.invalid }
            let committed = if let receiveWithConsent = storage.receiveWithConsent {
                try await receiveWithConsent(fragment, peerVoiceprintsAllowed)
            } else {
                try await storage.receive(fragment)
            }
            if let committed {
                guard committed == fragment.operationID else { throw AutomaticSyncWire.Failure.invalid }
                try await write(.init(kind: .ack, requestID: message.requestID, operationID: committed))
            }
        case .ack:
            guard accepted, let id = message.operationID, id == pendingID,
                   message.requestID == pendingRequestID,
                  let acknowledgement else { throw AutomaticSyncWire.Failure.invalid }
            // Retire the durable outbox before allowing the sender to advance.
            try await storage.acknowledge(id)
            // A local pause/revoke can cancel the waiter while SQLite is awaited.
            guard !stopped, pendingID == id, self.acknowledgement != nil else { return }
            self.acknowledgement = nil
            pendingID = nil
            pendingRequestID = nil
            deadline?.cancel()
            acknowledgement.resume()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onSending(false)
        peerVoiceprintsAllowed = false
        sender?.cancel()
        fragmentWriter?.cancel()
        deadline?.cancel()
        let waiter = acknowledgement
        acknowledgement = nil
        pendingID = nil
        pendingRequestID = nil
        waiter?.resume(throwing: CancellationError())
    }

    private func startSender() {
        guard sender == nil else { return }
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                if let changes = storage.changes {
                    for try await _ in changes() {
                        try await sendPending()
                    }
                } else {
                    while !Task.isCancelled, !stopped {
                        try await sendPending()
                        try await Task.sleep(for: .seconds(3))
                    }
                }
            } catch {
                guard !stopped else { return }
                onProblem(error)
                stop()
                onFailure()
            }
        }
    }

    private func sendPending() async throws {
        defer { onSending(false) }
        while !stopped {
            try Task.checkCancellation()
            guard try await storage.isEnabled() else { throw AutomaticSyncWire.Failure.disabled }
            let pending = if let pendingWithConsent = storage.pendingWithConsent {
                try await pendingWithConsent(peerVoiceprintsAllowed)
            } else {
                try await storage.pending()
            }
            onSending(!pending.isEmpty)
            for operation in pending {
                try Task.checkCancellation()
                guard try await storage.isEnabled() else { throw AutomaticSyncWire.Failure.disabled }
                try await transmit(operation)
            }
            if pending.count < 64 || storage.pendingWithConsent == nil { return }
        }
        throw CancellationError()
    }

    private func transmit(_ operation: AutomaticSyncWire.Operation) async throws {
        guard !stopped else { throw CancellationError() }
        if operation.biometric {
            guard peerVoiceprintsAllowed, try await storage.voiceprintsAllowed() else { return }
        }
        guard !stopped else { throw CancellationError() }
        let messages = try AutomaticSyncWire.fragments(for: operation).map {
            AutomaticSyncWire.Message(kind: .fragment, fragment: $0)
        }
        pendingID = operation.id
        pendingRequestID = messages.last?.requestID
        // Register the waiter before any write: a loopback peer may reply immediately.
        try await withCheckedThrowingContinuation { continuation in
            acknowledgement = continuation
            armDeadline()
            fragmentWriter = Task { [weak self] in
                guard let self else { return }
                do {
                    for message in messages {
                        guard !stopped, try await storage.isEnabled() else {
                            throw AutomaticSyncWire.Failure.disabled
                        }
                        if operation.biometric {
                            guard peerVoiceprintsAllowed, try await storage.voiceprintsAllowed() else {
                                throw AutomaticSyncWire.Failure.consentRequired
                            }
                        }
                        try await write(message)
                    }
                } catch {
                    guard !stopped else { return }
                    onProblem(error)
                    stop()
                    onFailure()
                }
            }
        }
    }

    private func write(_ message: AutomaticSyncWire.Message) async throws {
        guard !stopped else { throw CancellationError() }
        let bytes = try AutomaticSyncWire.encode(message)
        _ = try AutomaticSyncWire.decode(bytes)
        guard let value = String(data: bytes, encoding: .utf8) else { throw AutomaticSyncWire.Failure.invalid }
        try await send(.init(type: AutomaticSyncWire.messageType, value: value))
    }

    private func armDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !stopped else { return }
            onProblem(AutomaticSyncTransportError.timeout)
            stop()
            onFailure()
        }
    }
}

enum AutomaticSyncTransportError: LocalizedError {
    case timeout

    var errorDescription: String? {
        String(localized: "Synchronization timed out. Reconnect to retry.", table: "AutomaticSync")
    }
}
