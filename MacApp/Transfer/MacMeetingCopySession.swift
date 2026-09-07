import Foundation
import OSLog

/// Created only after bilateral authenticated ready; never owns a socket or cipher counter.
@MainActor
final class MacMeetingCopySession {
    struct Progress: Sendable, Equatable {
        let operationID: String
        let title: String
        let receivedBytes: Int
        let totalBytes: Int
    }

    enum Failure: Error, Equatable {
        case inactive, unauthorized, malformedMessage, wrongOrder, replay, requestLimit
        case operationMismatch, wrongOffset, concurrentRequest, invalidDigest
    }

    private struct Active {
        let operation: MeetingCopyWire.Operation
        let manifest: MeetingCopyWire.Manifest
        let offer: MacMeetingCopyInbox.Offer
        var audioOffset: Int
        var transcriptOffset: Int
    }

    private let inbox: MacMeetingCopyInbox
    private let peerIdentity: Data
    private let receiverIdentity: Data
    private let isAuthorized: @MainActor () throws -> Bool
    private let onProgress: @MainActor (Progress?) -> Void
    private let onCommit: @MainActor (MacMeetingCopyInbox.Receipt) async -> Void
    private let onFailure: @MainActor (MeetingCopyWire.Failure) -> Void
    private var live = true
    private var negotiated = false
    private var handling = false
    private var requests = Set<String>()
    private var active: Active?
    private static let logger = Logger(subsystem: "TranscriptMac", category: "MeetingCopy")
    private static let requestLimit = 262_200

    init(
        inbox: MacMeetingCopyInbox,
        peerIdentity: Data,
        receiverIdentity: Data,
        isAuthorized: @escaping @MainActor () throws -> Bool,
        onProgress: @escaping @MainActor (Progress?) -> Void = { _ in },
        onCommit: @escaping @MainActor (MacMeetingCopyInbox.Receipt) async -> Void = { _ in },
        onFailure: @escaping @MainActor (MeetingCopyWire.Failure) -> Void = { _ in }
    ) {
        self.inbox = inbox
        self.peerIdentity = peerIdentity
        self.receiverIdentity = receiverIdentity
        self.isAuthorized = isAuthorized
        self.onProgress = onProgress
        self.onCommit = onCommit
        self.onFailure = onFailure
    }

    func cancel() {
        live = false
        active = nil
        requests.removeAll()
        onProgress(nil)
    }

    func handle(_ inner: MacPairingMessage) async throws -> MacPairingMessage {
        do {
            try checkAuthorization()
            guard !handling else { throw Failure.concurrentRequest }
            handling = true
            defer { handling = false }
            let message: MeetingCopyWire.Message
            do { message = try MeetingCopyWire.message(inner) }
            catch { throw Failure.malformedMessage }
            guard !requests.contains(message.requestID) else { throw Failure.replay }
            guard requests.count < Self.requestLimit else { throw Failure.requestLimit }
            requests.insert(message.requestID)

            if message.type == .capabilities {
                guard !negotiated, active == nil else { throw Failure.wrongOrder }
                negotiated = true
                var accepted = MeetingCopyWire.Message(.accepted, requestID: message.requestID)
                accepted.capability = MeetingCopyWire.capability
                return try MeetingCopyWire.inner(accepted)
            }
            guard negotiated else { throw Failure.wrongOrder }
            guard [.offer, .chunk, .finalize].contains(message.type),
                  let operation = message.operation else { throw Failure.wrongOrder }
            do {
                let response = try await dispatch(message, operation: operation)
                try checkAuthorization()
                return try MeetingCopyWire.inner(response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as Failure {
                throw error
            } catch {
                try checkAuthorization()
                let failure = Self.wireFailure(error)
                active = nil
                onProgress(nil)
                onFailure(failure)
                try checkAuthorization()
                var response = MeetingCopyWire.Message(.failed, requestID: message.requestID)
                response.operation = operation
                response.failure = failure
                return try MeetingCopyWire.inner(response)
            }
        } catch {
            cancel()
            throw error
        }
    }

    private func dispatch(
        _ message: MeetingCopyWire.Message, operation: MeetingCopyWire.Operation
    ) async throws -> MeetingCopyWire.Message {
        switch message.type {
        case .offer:
            guard active == nil else { throw Failure.wrongOrder }
            guard let bytes = message.manifest else { throw Failure.malformedMessage }
            let manifest = try MeetingCopyWire.decodeManifest(bytes)
            // These are LOCAL capacity limits, not negotiated wire extensions. Reject
            // before reserve/status so the sender never mistakes acceptance for capacity.
            guard manifest.audio.length <= UInt64(MacMeetingCopyInbox.audioLimit),
                  manifest.transcript.length <= UInt64(MacMeetingCopyInbox.transcriptLimit) else {
                throw MeetingCopyWire.Failure.storage
            }
            let offer = try localOffer(operation, manifest: manifest, bytes: bytes)
            let status = try await inbox.reserve(offer)
            try checkAuthorization()
            if let receipt = status.receipt {
                return committed(receipt, message: message, operation: operation)
            }
            active = Active(operation: operation, manifest: manifest, offer: offer,
                            audioOffset: status.audio.offset, transcriptOffset: status.transcript.offset)
            publishProgress()
            var response = MeetingCopyWire.Message(.status, requestID: message.requestID)
            response.operation = operation
            response.audio = try Self.prefix(status.audio, asset: manifest.audio)
            response.transcript = try Self.prefix(status.transcript, asset: manifest.transcript)
            return response
        case .chunk:
            guard var current = active else { throw Failure.wrongOrder }
            guard current.operation == operation else { throw Failure.operationMismatch }
            guard let asset = message.asset, let offset = message.offset, let bytes = message.bytes,
                  let digest = message.sha256 else { throw Failure.malformedMessage }
            let descriptor = asset == .audio ? current.manifest.audio : current.manifest.transcript
            let expected = asset == .audio ? current.audioOffset : current.transcriptOffset
            // The inbox's local API allows idempotent chunk retries; the fixed wire does
            // not. Only a fresh authenticated session's offer/status may resume a prefix.
            guard offset == UInt64(expected), offset <= descriptor.length,
                  UInt64(bytes.count) <= descriptor.length - offset else { throw Failure.wrongOffset }
            let prefix = try await inbox.append(
                bytes, asset: asset == .audio ? .audio : .transcript, offset: expected,
                sha256: SHA256Digest(base64: digest).hex, offer: current.offer
            )
            try checkAuthorization()
            guard prefix.offset == expected + bytes.count else { throw Failure.wrongOffset }
            if asset == .audio { current.audioOffset = prefix.offset }
            else { current.transcriptOffset = prefix.offset }
            active = current
            publishProgress()
            var response = MeetingCopyWire.Message(.ack, requestID: message.requestID)
            response.operation = operation
            response.asset = asset
            response.prefix = try Self.prefix(prefix, asset: descriptor)
            return response
        case .finalize:
            guard let current = active else { throw Failure.wrongOrder }
            guard current.operation == operation else { throw Failure.operationMismatch }
            let manifest = current.manifest
            let receipt = try await inbox.finalize(current.offer) { bytes in
                let transcript: MeetingCopyWire.Transcript
                do {
                    transcript = try MeetingCopyWire.decode(
                        MeetingCopyWire.Transcript.self, from: bytes, limit: MeetingCopyWire.transcriptLimit
                    )
                    try transcript.validate(manifest: manifest)
                } catch {
                    throw MacMeetingCopyInbox.Failure.invalidTranscript
                }
                return MacMeetingCopyInbox.Transcript(
                    revision: transcript.revision, parentRevision: transcript.parentRevision,
                    locale: transcript.locale, segments: transcript.utterances.map {
                        MacMeetingCopyInbox.Segment(
                            id: $0.id, startMs: Int($0.startMs), endMs: Int($0.endMs), text: $0.text,
                            locale: $0.locale, revision: $0.revision, source: $0.source
                        )
                    }
                )
            }
            try checkAuthorization()
            active = nil
            onProgress(nil)
            await onCommit(receipt)
            try checkAuthorization()
            return committed(receipt, message: message, operation: operation)
        default:
            throw Failure.wrongOrder
        }
    }

    private func checkAuthorization() throws {
        try Task.checkCancellation()
        guard live else { throw Failure.inactive }
        guard peerIdentity.count == 32, receiverIdentity.count == 32,
              peerIdentity != receiverIdentity else { throw Failure.unauthorized }
        do {
            guard try isAuthorized() else { throw Failure.unauthorized }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A transient trust-store read failure is never a recoverable inbox storage
            // failure. Close even if a later authorization read might succeed.
            throw Failure.unauthorized
        }
    }

    private func publishProgress() {
        guard let active else { onProgress(nil); return }
        onProgress(Progress(
            operationID: active.operation.id, title: active.manifest.title,
            receivedBytes: active.audioOffset + active.transcriptOffset,
            totalBytes: active.offer.manifest.audio.byteCount + active.offer.manifest.transcript.byteCount
        ))
    }

    private func committed(
        _ receipt: MacMeetingCopyInbox.Receipt,
        message: MeetingCopyWire.Message, operation: MeetingCopyWire.Operation
    ) -> MeetingCopyWire.Message {
        var response = MeetingCopyWire.Message(.committed, requestID: message.requestID)
        response.operation = operation
        response.receiptID = receipt.id.uuidString.lowercased()
        return response
    }

    private func localOffer(
        _ operation: MeetingCopyWire.Operation, manifest m: MeetingCopyWire.Manifest, bytes: Data
    ) throws -> MacMeetingCopyInbox.Offer {
        guard let id = UUID(uuidString: operation.id) else { throw Failure.malformedMessage }
        // Local provenance is "paired-" + hexadecimal of the FULL authenticated public
        // key, not a sender field, truncated identifier, speaker identity or wire extension.
        let origin = "paired-" + peerIdentity.map { String(format: "%02x", $0) }.joined()
        return try MacMeetingCopyInbox.Offer(
            peerIdentity: peerIdentity, receiverIdentity: receiverIdentity, operationID: id,
            manifestSnapshot: bytes, manifestSHA256: SHA256Digest(base64: operation.manifestSHA256).hex,
            manifest: MacMeetingCopyInbox.Manifest(
                meetingID: m.meetingID, title: m.title, startedAtMs: m.startedAtMs,
                createdAtMs: m.createdAtMs, updatedAtMs: m.updatedAtMs, durationMs: Int(m.durationMs),
                locale: m.locale, originDeviceID: origin,
                audio: .init(byteCount: Int(m.audio.length), sha256: SHA256Digest(base64: m.audio.sha256).hex),
                transcript: .init(byteCount: Int(m.transcript.length), sha256: SHA256Digest(base64: m.transcript.sha256).hex),
                revision: m.transcriptRevision, parentRevision: m.parentRevision, source: m.source
            )
        )
    }

    private static func prefix(
        _ prefix: MacMeetingCopyInbox.Prefix, asset: MeetingCopyWire.Asset
    ) throws -> MeetingCopyWire.Prefix {
        guard prefix.offset >= 0, UInt64(prefix.offset) <= asset.length else { throw Failure.wrongOffset }
        return try MeetingCopyWire.Prefix(asset: asset, offset: UInt64(prefix.offset),
                                           prefixSHA256: SHA256Digest(hex: prefix.sha256).base64)
    }

    private static func wireFailure(_ error: Error) -> MeetingCopyWire.Failure {
        if let failure = error as? MeetingCopyWire.Failure { return failure }
        if let failure = error as? MacMeetingCopyInbox.Failure {
            switch failure {
            case .meetingExists: return .conflict
            case .quotaExceeded: return .storage
            case .cancelled: return .cancelled
            case .invalidOffer, .unauthorized, .conflictingOperation, .unknownOperation,
                 .invalidChunk, .wrongOffset, .digestMismatch, .incomplete,
                 .invalidTranscript, .invalidAudio, .unsafeFile: return .invalid
            }
        }
        // Never log SQL parameters, paths, transcript, peer keys or arbitrary error text.
        logger.error("Meeting copy storage operation failed; no receipt sent")
        return .storage
    }

    private struct SHA256Digest {
        let bytes: Data
        init(base64: String) throws {
            guard MeetingCopyWire.validHash(base64), let bytes = Data(base64Encoded: base64) else {
                throw Failure.invalidDigest
            }
            self.bytes = bytes
        }
        init(hex: String) throws {
            let characters = Array(hex.utf8)
            guard characters.count == 64,
                  characters.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidDigest
            }
            func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
            bytes = Data(stride(from: 0, to: 64, by: 2).map {
                nibble(characters[$0]) * 16 + nibble(characters[$0 + 1])
            })
        }
        var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
        var base64: String { bytes.base64EncodedString() }
    }
}
