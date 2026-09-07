import Foundation
import GRDB
import TranscriptCore

/// Independently negotiated, receiver-driven immutable resources. A metadata ack
/// never marks an audio/analysis/voiceprint payload as received.
@MainActor
final class AutomaticSyncResourceChannel {
    typealias Wire = AutomaticSyncResourceWire
    typealias Send = AutomaticSyncChannel.Send
    typealias Factory = @MainActor (MacPairedDevice, @escaping Send) -> AutomaticSyncResourceChannel?

    struct AudioImport: Sendable {
        let meetingID: String
        let inputRevision: String
        let peerID: String
        let operationID: String
    }

    struct Progress: Sendable, Equatable {
        let received: Int64
        let total: Int64?
    }

    struct Storage {
        var isEnabled: @MainActor () async throws -> Bool
        var missing: @MainActor () async throws -> [String]
        var progress: @MainActor (String) async throws -> Int64
        var chunk: @MainActor (String, Int64) async throws -> Wire.Chunk?
        var receive: @MainActor (Wire.Chunk) async throws -> Int64
        var complete: @MainActor (String) async throws -> Void
        var reconcile: (@MainActor () async throws -> [AutomaticSyncRepository.ResourceApplicationOutcome])?
        var changes: (@MainActor () -> AsyncValueObservation<Void>)?

        @MainActor static func repository(
            database: AppDatabase, peer: MacPairedDevice, audioDirectory: URL,
            isTrusted: @escaping @MainActor () throws -> Bool,
            peerAllowsVoiceprints: @escaping @MainActor () -> Bool,
            onAudioImported: @escaping @MainActor (AudioImport) async throws -> Void = { _ in }
        ) -> Self {
            let repository = AutomaticSyncRepository(database)
            let id = AutomaticSyncChannel.peerID(peer)
            let transfer = AutomaticSyncResourceTransfer(database, directory: audioDirectory)
            return Self(
                isEnabled: {
                    guard try isTrusted() else { return false }
                    let status = try await repository.status(peerID: id)
                    return try isTrusted() && status.enabled
                },
                missing: {
                    guard try isTrusted() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
                    return try await repository.resourcesNeedingDownload(
                        from: id, limit: 64, includeBiometrics: peerAllowsVoiceprints()
                    )
                },
                progress: {
                    guard try isTrusted() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
                    return try await transfer.progress(resourceID: $0, from: id)
                },
                chunk: {
                    guard try isTrusted() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
                    if try await repository.resource(id: $0)?.kind == .voiceprint {
                        guard peerAllowsVoiceprints() else { throw AutomaticSyncRepository.Wire.Failure.consentRequired }
                    }
                    return try await transfer.chunk(resourceID: $0, offset: $1, for: id, audioDirectory: audioDirectory)
                },
                receive: { chunk in
                    guard try isTrusted() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
                    if try await repository.resource(id: chunk.resourceID)?.kind == .voiceprint {
                        guard peerAllowsVoiceprints() else { throw AutomaticSyncRepository.Wire.Failure.consentRequired }
                    }
                    do { return try await transfer.receive(chunk, from: id) }
                    catch AutomaticSyncRepository.Wire.Failure.hashMismatch {
                        try await transfer.discardPartial(resourceID: chunk.resourceID, from: id)
                        throw AutomaticSyncRepository.Wire.Failure.hashMismatch
                    }
                },
                complete: { resourceID in
                    guard try isTrusted(),
                          let descriptor = try await repository.resource(id: resourceID),
                          try await transfer.progress(resourceID: resourceID, from: id) == descriptor.byteCount else {
                        throw AutomaticSyncRepository.Wire.Failure.resourceUnavailable
                    }
                    switch descriptor.kind {
                    case .audio:
                        try await repository.adoptAudioResource(id: resourceID)
                        let imports = try await repository.verifiedAudioImports()
                        guard let imported = imports.first(where: { $0.resourceID == resourceID && $0.peerID == id }) else {
                            throw AutomaticSyncRepository.Wire.Failure.invalid
                        }
                        let status = try await repository.status(peerID: id)
                        guard try isTrusted(), status.enabled else { throw AutomaticSyncRepository.Wire.Failure.disabled }
                        try await onAudioImported(.init(
                            meetingID: imported.meetingID, inputRevision: imported.audioSHA256,
                            peerID: imported.peerID, operationID: imported.operationID
                        ))
                    case .analysis, .transcript:
                        try await repository.publishResource(id: resourceID)
                    case .voiceprint:
                        try await repository.adoptVoiceprintResource(id: resourceID)
                    }
                },
                reconcile: {
                    guard try isTrusted() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
                    let outcomes = try await repository.reconcileVerifiedResources(
                        from: id, includeBiometrics: peerAllowsVoiceprints()
                    )
                    for outcome in outcomes where outcome.status == .applied {
                        guard try isTrusted() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
                        if let imported = try await repository.verifiedAudioImports().first(where: {
                            $0.resourceID == outcome.resourceID && $0.peerID == id
                        }) {
                            try await onAudioImported(.init(
                                meetingID: imported.meetingID, inputRevision: imported.audioSHA256,
                                peerID: imported.peerID, operationID: imported.operationID
                            ))
                        }
                    }
                    return outcomes
                },
                changes: { repository.changes() }
            )
        }
    }

    private let storage: Storage
    private let send: Send
    private let onFailure: @MainActor () -> Void
    private let onProblem: @MainActor (any Error) -> Void
    private let onProgress: @MainActor (Progress?) -> Void
    private var accepted = false
    private var stopped = false
    private var helloID: String?
    private var request: Wire.Message?
    private var reply: CheckedContinuation<Wire.Message, any Error>?
    private var deadline: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var requestWriter: Task<Void, Never>?

    init(
        storage: Storage, send: @escaping Send, onFailure: @escaping @MainActor () -> Void,
        onProblem: @escaping @MainActor (any Error) -> Void = { _ in },
        onProgress: @escaping @MainActor (Progress?) -> Void = { _ in }
    ) {
        self.storage = storage
        self.send = send
        self.onFailure = onFailure
        self.onProblem = onProblem
        self.onProgress = onProgress
    }

    func negotiate() async throws {
        guard !stopped, try await storage.isEnabled(), !stopped else { return }
        let hello = Wire.Message(kind: .hello)
        helloID = hello.requestID
        armDeadline()
        try await write(hello)
    }

    func handle(_ inner: MacPairingMessage) async throws {
        guard !stopped, try await storage.isEnabled(), !stopped,
              inner.type == Wire.messageType, let value = inner.value else {
            throw AutomaticSyncRepository.Wire.Failure.disabled
        }
        let message = try Wire.decode(Data(value.utf8))
        switch message.kind {
        case .hello:
            guard !accepted, helloID == nil else { throw AutomaticSyncRepository.Wire.Failure.invalid }
            try await write(.init(kind: .accepted, requestID: message.requestID))
            accepted = true
            startWorker()
        case .accepted:
            guard !accepted, helloID == message.requestID else { throw AutomaticSyncRepository.Wire.Failure.invalid }
            helloID = nil
            deadline?.cancel()
            accepted = true
            startWorker()
        case .request:
            guard accepted, let id = message.resourceID, let offset = message.offset else {
                throw AutomaticSyncRepository.Wire.Failure.invalid
            }
            do {
                if let chunk = try await storage.chunk(id, offset) {
                    try await write(.init(kind: .chunk, requestID: message.requestID, chunk: chunk))
                } else {
                    try await write(.init(kind: .ack, requestID: message.requestID, resourceID: id, offset: offset))
                }
            } catch AutomaticSyncRepository.Wire.Failure.resourceUnavailable {
                try await write(.init(kind: .unavailable, requestID: message.requestID, resourceID: id))
            }
        case .chunk, .ack, .unavailable:
            guard accepted, let request, let reply, request.requestID == message.requestID else {
                throw AutomaticSyncRepository.Wire.Failure.invalid
            }
            if let chunk = message.chunk {
                guard chunk.resourceID == request.resourceID, chunk.offset == request.offset else {
                    throw AutomaticSyncRepository.Wire.Failure.invalid
                }
            } else {
                guard message.resourceID == request.resourceID,
                      message.kind != .ack || message.offset == request.offset else {
                    throw AutomaticSyncRepository.Wire.Failure.invalid
                }
            }
            self.request = nil
            self.reply = nil
            deadline?.cancel()
            reply.resume(returning: message)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onProgress(nil)
        worker?.cancel()
        requestWriter?.cancel()
        deadline?.cancel()
        let waiter = reply
        reply = nil
        request = nil
        waiter?.resume(throwing: CancellationError())
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                if let changes = storage.changes {
                    for try await _ in changes() {
                        try await synchronizeResources()
                    }
                } else {
                    while !stopped, !Task.isCancelled {
                        try await synchronizeResources()
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

    private func synchronizeResources() async throws {
        try Task.checkCancellation()
        guard !stopped, try await storage.isEnabled() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
        for id in try await storage.missing() {
            try Task.checkCancellation()
            do { try await download(id) }
            catch AutomaticSyncRepository.Wire.Failure.resourceUnavailable {
                onProgress(nil)
                onProblem(AutomaticSyncRepository.Wire.Failure.resourceUnavailable)
            } catch AutomaticSyncRepository.Wire.Failure.staleRevision {
                onProgress(nil)
                onProblem(AutomaticSyncRepository.Wire.Failure.staleRevision)
            }
        }
        if let reconcile = storage.reconcile {
            for outcome in try await reconcile() {
                switch outcome.status {
                case .applied: break
                case .stale: onProblem(AutomaticSyncRepository.Wire.Failure.staleRevision)
                case .unavailable: onProblem(AutomaticSyncRepository.Wire.Failure.resourceUnavailable)
                case .failed: throw AutomaticSyncRepository.Wire.Failure.invalid
                }
            }
        }
    }

    private func download(_ id: String) async throws {
        var offset = try await storage.progress(id)
        onProgress(.init(received: offset, total: nil))
        while !stopped {
            guard try await storage.isEnabled() else { throw AutomaticSyncRepository.Wire.Failure.disabled }
            let response = try await exchange(.init(kind: .request, resourceID: id, offset: offset))
            if response.kind == .unavailable { throw AutomaticSyncRepository.Wire.Failure.resourceUnavailable }
            if response.kind == .ack {
                // The sender saying EOF is insufficient: the local store must have
                // already verified and committed the complete content-addressed file.
                try await storage.complete(id)
                onProgress(nil)
                return
            }
            guard let chunk = response.chunk else { throw AutomaticSyncRepository.Wire.Failure.invalid }
            let next = try await storage.receive(chunk)
            guard next > offset, next <= chunk.total else { throw AutomaticSyncRepository.Wire.Failure.invalid }
            offset = next
            onProgress(.init(received: offset, total: chunk.total))
            if offset == chunk.total {
                try await storage.complete(id)
                onProgress(nil)
                return
            }
        }
        throw CancellationError()
    }

    private func exchange(_ message: Wire.Message) async throws -> Wire.Message {
        guard !stopped, reply == nil else { throw AutomaticSyncRepository.Wire.Failure.invalid }
        return try await withCheckedThrowingContinuation { continuation in
            request = message
            reply = continuation
            armDeadline()
            requestWriter = Task { [weak self] in
                guard let self else { return }
                do { try await write(message) }
                catch {
                    guard !stopped else { return }
                    onProblem(error)
                    stop()
                    onFailure()
                }
            }
        }
    }

    private func write(_ message: Wire.Message) async throws {
        guard !stopped else { throw CancellationError() }
        let bytes = try AutomaticSyncRepository.Wire.encode(message)
        _ = try Wire.decode(bytes)
        try await send(.init(type: Wire.messageType, value: String(decoding: bytes, as: UTF8.self)))
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
