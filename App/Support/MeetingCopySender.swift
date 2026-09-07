import CryptoKit
import Foundation
import GRDB
import OSLog
import TranscriptCore

@MainActor
final class MeetingCopySender {
    private let client: IOSMacPairingClient
    private let repository: MeetingCopyOutbox
    private let store: AudioFileStore
    private var task: Task<Void, Never>?
    private var activeID: String?
    private var preparing = false
    private let diagnostic: (MeetingCopyProblem.Code, Int32?) -> Void
    private(set) var unpersistedFailures: [String: MeetingCopyProblem] = [:]
    var onChange: (() -> Void)?
    var sendingID: String? { activeID }

    init(client: IOSMacPairingClient, database: AppDatabase, store: AudioFileStore,
         diagnostic: @escaping (MeetingCopyProblem.Code, Int32?) -> Void = { code, sqliteCode in
             Logger(subsystem: "com.transcript", category: "MeetingCopy")
                 .error("Could not persist transfer failure: \(code.rawValue, privacy: .public), SQLite code: \(sqliteCode ?? -1)")
         }) {
        self.client = client
        self.repository = MeetingCopyOutbox(database)
        self.store = store
        self.diagnostic = diagnostic
    }

    func summaries() async throws -> [MeetingCopyOutbox.Summary] {
        let summaries = try await repository.summaries()
        let retained = Set(summaries.map(\.id))
        unpersistedFailures = unpersistedFailures.filter { retained.contains($0.key) }
        return summaries
    }

    func enqueue(meetingID: String) async throws {
        guard task == nil, !preparing else { throw MeetingCopyProblem(code: .localBusy) }
        preparing = true
        defer { preparing = false }
        _ = try await summaries()
        try await client.negotiateMeetingCopy()
        guard let peer = client.pairedPeer, let sessionID = client.transferSessionID else {
            throw MeetingCopyWire.Failure.incompatible
        }
        let snapshot = try await repository.snapshot(meetingID: meetingID)
        let export = try await Self.makeExport(snapshot, store: store)
        guard client.transferSessionID == sessionID else { throw MeetingCopyWire.Failure.incompatible }
        let entry = try await repository.enqueue(snapshot: snapshot, peerKey: peer.publicKey,
                                                 manifest: export.manifest, transcript: export.transcript,
                                                 sourceIdentity: export.identity)
        onChange?()
        start(entry.id)
    }

    func retry(id: String) async throws {
        guard task == nil, !preparing else { throw MeetingCopyProblem(code: .localBusy) }
        preparing = true
        defer { preparing = false }
        _ = try await summaries()
        try await client.negotiateMeetingCopy()
        let entry = try await repository.entry(id: id)
        guard entry.peerKey == client.pairedPeer?.publicKey else { throw MeetingCopyWire.Failure.invalid }
        guard entry.state != "done" else { return }
        try await repository.retry(id: id)
        start(id)
    }

    func cancel(id: String) async throws {
        // Persist before closing the socket. A remote commit may already exist.
        try await repository.cancel(id: id)
        unpersistedFailures.removeValue(forKey: id)
        if activeID == id {
            task?.cancel()
            client.disconnect()
        }
        onChange?()
    }

    private func start(_ id: String) {
        guard task == nil else { return }
        activeID = id
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.activeID = nil; self.onChange?() }
            self.onChange?()
            do {
                try await self.send(id)
                self.unpersistedFailures.removeValue(forKey: id)
            }
            catch {
                self.client.disconnect()
                if Task.isCancelled { return } // cancel(id:) already persisted the local stop.
                let problem = MeetingCopyProblem(error)
                do {
                    try await self.repository.noteFailure(id: id, message: problem.code.rawValue)
                    self.unpersistedFailures.removeValue(forKey: id)
                } catch {
                    self.unpersistedFailures[id] = problem
                    self.diagnostic(problem.code, (error as? DatabaseError)?.resultCode.rawValue)
                }
            }
        }
    }

    private func send(_ id: String) async throws {
        let entry = try await repository.entry(id: id)
        guard let sessionID = client.transferSessionID, entry.peerKey == client.pairedPeer?.publicKey else {
            throw MeetingCopyWire.Failure.incompatible
        }
        let snapshot = try await repository.validate(id: id)
        let manifest = try await Self.validateEntry(entry)
        guard let fileName = snapshot.meeting.audioFileName else { throw MeetingCopyWire.Failure.invalid }
        let reader = try MeetingCopyAudioReader(url: store.url(forFileName: fileName))
        do {
            try await reader.verify(expected: manifest.audio, frozenIdentity: entry.sourceIdentity)
            let operation = MeetingCopyWire.Operation(id: entry.id, meetingID: manifest.meetingID,
                                                       manifestSHA256: MeetingCopyWire.hash(entry.manifest))
            var offer = MeetingCopyWire.Message(.offer)
            offer.operation = operation
            offer.manifest = entry.manifest
            let response = try await exchange(offer, entry: entry, sessionID: sessionID)
            if response.type == .committed {
                try await save(response, entry: entry)
                try await reader.close()
                return
            }
            guard response.type == .status, let audio = response.audio, let text = response.transcript,
                  audio.asset == manifest.audio, text.asset == manifest.transcript else { throw MeetingCopyWire.Failure.invalid }
            try await reader.resume(audio)
            var audioOffset = audio.offset
            while audioOffset < manifest.audio.length {
                let (bytes, prefixHash) = try await reader.chunk()
                try await sendChunk(bytes, offset: audioOffset, prefixHash: prefixHash, asset: .audio,
                                    descriptor: manifest.audio, operation: operation, entry: entry, sessionID: sessionID)
                audioOffset += UInt64(bytes.count)
            }
            var textHash = SHA256()
            let prefix = entry.transcript.prefix(Int(text.offset))
            textHash.update(data: prefix)
            guard Data(textHash.finalize()).base64EncodedString() == text.prefixSHA256 else { throw MeetingCopyWire.Failure.invalid }
            var textOffset = Int(text.offset)
            while textOffset < entry.transcript.count {
                let end = min(entry.transcript.count, textOffset + MeetingCopyWire.chunkLimit)
                let bytes = entry.transcript.subdata(in: textOffset..<end)
                textHash.update(data: bytes)
                try await sendChunk(bytes, offset: UInt64(textOffset),
                                    prefixHash: Data(textHash.finalize()).base64EncodedString(), asset: .transcript,
                                    descriptor: manifest.transcript, operation: operation, entry: entry, sessionID: sessionID)
                textOffset = end
            }
            try await reader.verify(expected: manifest.audio, frozenIdentity: entry.sourceIdentity)
            var finalize = MeetingCopyWire.Message(.finalize)
            finalize.operation = operation
            let receipt = try await exchange(finalize, entry: entry, sessionID: sessionID)
            guard receipt.type == .committed else { throw MeetingCopyWire.Failure.invalid }
            try await save(receipt, entry: entry)
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }

    private func sendChunk(_ bytes: Data, offset: UInt64, prefixHash: String, asset: MeetingCopyWire.AssetName,
                           descriptor: MeetingCopyWire.Asset, operation: MeetingCopyWire.Operation,
                           entry: MeetingCopyOutbox.Entry, sessionID: UUID) async throws {
        var chunk = MeetingCopyWire.Message(.chunk)
        chunk.operation = operation
        chunk.asset = asset
        chunk.offset = offset
        chunk.bytes = bytes
        chunk.sha256 = MeetingCopyWire.hash(bytes)
        let ack = try await exchange(chunk, entry: entry, sessionID: sessionID)
        guard ack.type == .ack, ack.asset == asset, let prefix = ack.prefix,
              prefix.asset == descriptor, prefix.offset == offset + UInt64(bytes.count),
              prefix.prefixSHA256 == prefixHash else { throw MeetingCopyWire.Failure.invalid }
    }

    private func exchange(_ message: MeetingCopyWire.Message, entry: MeetingCopyOutbox.Entry,
                          sessionID: UUID) async throws -> MeetingCopyWire.Message {
        try Task.checkCancellation()
        // Fresh source validation before every network write also notices local deletion/cancel.
        try await repository.assertPending(id: entry.id)
        guard client.transferSessionID == sessionID else { throw MeetingCopyWire.Failure.incompatible }
        let response = try await client.exchange(message)
        guard client.transferSessionID == sessionID, response.operation == message.operation else {
            throw MeetingCopyWire.Failure.invalid
        }
        if response.type == .failed { throw response.failure ?? MeetingCopyWire.Failure.invalid }
        return response
    }

    private func save(_ receipt: MeetingCopyWire.Message, entry: MeetingCopyOutbox.Entry) async throws {
        guard receipt.type == .committed, receipt.receiptID != nil else { throw MeetingCopyWire.Failure.invalid }
        try await repository.recordReceipt(id: entry.id, manifest: entry.manifest, receipt: MeetingCopyWire.encode(receipt))
    }

    private struct Export: Sendable { let manifest: Data; let transcript: Data; let identity: Data }

    nonisolated private static func validateEntry(_ entry: MeetingCopyOutbox.Entry) async throws -> MeetingCopyWire.Manifest {
        let manifest = try MeetingCopyWire.decodeManifest(entry.manifest)
        guard manifest.meetingID == entry.meetingId.lowercased(),
              manifest.transcript.length == entry.transcript.count,
              manifest.transcript.sha256 == MeetingCopyWire.hash(entry.transcript) else { throw MeetingCopyWire.Failure.invalid }
        let transcript = try MeetingCopyWire.decode(MeetingCopyWire.Transcript.self, from: entry.transcript,
                                                    limit: MeetingCopyWire.transcriptLimit)
        try transcript.validate(manifest: manifest)
        return manifest
    }

    nonisolated private static func makeExport(_ snapshot: MeetingCopyOutbox.Snapshot, store: AudioFileStore) async throws -> Export {
        let meeting = snapshot.meeting
        guard let fileName = meeting.audioFileName, let hex = meeting.audioSHA256,
              hex.utf8.count == 64,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let length = meeting.audioByteCount, length > 0 else { throw MeetingCopyWire.Failure.invalid }
        let digest = stride(from: 0, to: hex.count, by: 2).compactMap { index -> UInt8? in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        }
        guard digest.count == 32 else { throw MeetingCopyWire.Failure.invalid }
        let audio = MeetingCopyWire.Asset(length: UInt64(length), sha256: Data(digest).base64EncodedString())
        let reader = try MeetingCopyAudioReader(url: store.url(forFileName: fileName))
        do {
            try await reader.verify(expected: audio)
            let identity = try await reader.identityBytes()
            try await reader.close()
            let revision = UUID().uuidString.lowercased()
            let transcript = MeetingCopyWire.Transcript(revision: revision, parentRevision: nil, locale: meeting.localeIdentifier,
                utterances: snapshot.utterances.map {
                    .init(id: $0.id.lowercased(), startMs: Int64($0.startMs), endMs: Int64($0.endMs),
                          text: $0.text, locale: $0.localeIdentifier, revision: $0.revision, source: $0.engine.rawValue)
                })
            let text = try MeetingCopyWire.encode(transcript)
            let manifest = MeetingCopyWire.Manifest(meetingID: meeting.id.lowercased(), title: meeting.title,
                startedAtMs: try milliseconds(meeting.startedAt), createdAtMs: try milliseconds(meeting.createdAt),
                updatedAtMs: try milliseconds(meeting.updatedAt), durationMs: Int64(meeting.durationMs),
                locale: meeting.localeIdentifier, audio: audio,
                transcript: .init(length: UInt64(text.count), sha256: MeetingCopyWire.hash(text)),
                transcriptRevision: revision, parentRevision: nil, source: "publishedLocalTranscript")
            try manifest.validate()
            try transcript.validate(manifest: manifest)
            let bytes = try MeetingCopyWire.encode(manifest)
            _ = try MeetingCopyWire.decodeManifest(bytes)
            return Export(manifest: bytes, transcript: text, identity: identity)
        } catch {
            try? await reader.close()
            throw error
        }
    }

    nonisolated private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value <= 253_402_300_799_999 else { throw MeetingCopyWire.Failure.invalid }
        return Int64(value.rounded(.down))
    }
}
