import CryptoKit
import Foundation
import GRDB
import OSLog
import TranscriptCore

@MainActor
final class MeetingCopySender {
    @MainActor
    final class LegacyPreview: Equatable {
        let identifierCount: Int
        let rawSnapshotFingerprint: Data
        fileprivate let peerKey: Data
        private enum State { case pending, approved, consumed, cancelled }
        private var state = State.pending

        fileprivate init(count: Int, fingerprint: Data, peerKey: Data) {
            identifierCount = count
            rawSnapshotFingerprint = fingerprint
            self.peerKey = peerKey
        }

        func confirm() { if state == .pending { state = .approved } }
        func cancel() { state = .cancelled }
        fileprivate var isApproved: Bool { state == .approved }
        fileprivate var isPending: Bool { state == .pending }
        fileprivate func consume() { state = .consumed }
        nonisolated static func == (lhs: LegacyPreview, rhs: LegacyPreview) -> Bool { lhs === rhs }
    }

    private let client: IOSMacPairingClient
    private let repository: MeetingCopyOutbox
    private let store: AudioFileStore
    private var task: Task<Void, Never>?
    private var activeID: String?
    private var preparing = false
    private var pendingLegacyPreview: LegacyPreview?
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
        var stage = MeetingCopyProblem.Stage.snapshot
        var usedLegacyConsent = false
        do {
        _ = try await summaries()
        try Task.checkCancellation()
        let snapshot = try await repository.snapshot(meetingID: meetingID)
        let fingerprint = try MeetingCopyOutbox.sourceFingerprint(snapshot)
        stage = .negotiation
        guard let peer = client.pairedPeer else {
            throw MeetingCopyWire.Failure.incompatible
        }
        if let preview = pendingLegacyPreview, preview.isApproved,
           preview.rawSnapshotFingerprint != fingerprint || preview.peerKey != peer.publicKey {
            throw MeetingCopyProblem(code: .legacyPreviewChanged, stage: .snapshot)
        }
        stage = .transcriptValidation
        let legacyCount = try MeetingCopyOutbox.legacyIdentifierCount(in: snapshot)
        var allowingLegacy = false
        if legacyCount > 0 {
            if let preview = pendingLegacyPreview, preview.isApproved,
               preview.rawSnapshotFingerprint == fingerprint, preview.peerKey == peer.publicKey {
                preview.consume()
                pendingLegacyPreview = nil
                allowingLegacy = true
                usedLegacyConsent = true
            } else {
                let preview: LegacyPreview
                if let pending = pendingLegacyPreview, pending.isPending,
                   pending.rawSnapshotFingerprint == fingerprint, pending.peerKey == peer.publicKey {
                    preview = pending
                } else {
                    pendingLegacyPreview?.cancel()
                    preview = LegacyPreview(count: legacyCount, fingerprint: fingerprint, peerKey: peer.publicKey)
                    pendingLegacyPreview = preview
                }
                throw MeetingCopyProblem(code: .legacyConsentRequired, stage: .transcriptValidation, legacyPreview: preview)
            }
        } else {
            pendingLegacyPreview?.cancel()
            pendingLegacyPreview = nil
        }
        stage = .negotiation
        try await client.negotiateMeetingCopy()
        guard let sessionID = client.transferSessionID, client.pairedPeer?.publicKey == peer.publicKey else {
            throw MeetingCopyWire.Failure.incompatible
        }
        let export = try await Self.makeExport(snapshot, store: store, allowingLegacy: allowingLegacy)
        stage = .negotiation
        guard client.transferSessionID == sessionID else { throw MeetingCopyProblem(code: .network) }
        stage = .outboxSave
        let entry = try await repository.enqueue(snapshot: snapshot, peerKey: peer.publicKey,
                                                 manifest: export.manifest, transcript: export.transcript,
                                                 sourceIdentity: export.identity)
        onChange?()
        start(entry.id)
        } catch {
            let original = MeetingCopyProblem(error, stage: stage)
            let problem = usedLegacyConsent && original.code == .staleSnapshot
                ? MeetingCopyProblem(code: .legacyPreviewChanged, stage: .snapshot) : original
            if problem.code != .legacyConsentRequired {
                pendingLegacyPreview?.cancel()
                pendingLegacyPreview = nil
            }
            throw problem
        }
    }

    func retry(id: String) async throws {
        guard task == nil, !preparing else { throw MeetingCopyProblem(code: .localBusy) }
        preparing = true
        defer { preparing = false }
        var stage = MeetingCopyProblem.Stage.snapshot
        do {
        _ = try await summaries()
        stage = .negotiation
        try await client.negotiateMeetingCopy()
        stage = .snapshot
        let entry = try await repository.entry(id: id)
        guard entry.peerKey == client.pairedPeer?.publicKey else { throw MeetingCopyWire.Failure.invalid }
        guard entry.state != "done" else { return }
        stage = .outboxSave
        try await repository.retry(id: id)
        start(id)
        } catch { throw MeetingCopyProblem(error, stage: stage) }
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
                    try await self.repository.noteFailure(id: id, message: problem.storedValue)
                    self.unpersistedFailures.removeValue(forKey: id)
                } catch {
                    self.unpersistedFailures[id] = problem
                    self.diagnostic(problem.code, (error as? DatabaseError)?.resultCode.rawValue)
                }
            }
        }
    }

    private func send(_ id: String) async throws {
        var stage = MeetingCopyProblem.Stage.snapshot
        do {
        let entry = try await repository.entry(id: id)
        stage = .negotiation
        guard let sessionID = client.transferSessionID, entry.peerKey == client.pairedPeer?.publicKey else {
            throw MeetingCopyWire.Failure.incompatible
        }
        stage = .snapshot
        let snapshot = try await repository.validate(id: id)
        stage = .transcriptValidation
        let manifest = try await Self.validateEntry(entry)
        stage = .audioVerification
        guard let fileName = snapshot.meeting.audioFileName else { throw MeetingCopyWire.Failure.invalid }
        let reader = try MeetingCopyAudioReader(url: store.url(forFileName: fileName))
        do {
            try await reader.verify(expected: manifest.audio, frozenIdentity: entry.sourceIdentity)
            let operation = MeetingCopyWire.Operation(id: entry.id, meetingID: manifest.meetingID,
                                                       manifestSHA256: MeetingCopyWire.hash(entry.manifest))
            var offer = MeetingCopyWire.Message(.offer)
            offer.operation = operation
            offer.manifest = entry.manifest
            stage = .offer
            let response = try await exchange(offer, entry: entry, sessionID: sessionID)
            if response.type == .committed {
                try await save(response, entry: entry)
                try await reader.close()
                return
            }
            guard response.type == .status, let audio = response.audio, let text = response.transcript,
                  audio.asset == manifest.audio, text.asset == manifest.transcript else { throw MeetingCopyWire.Failure.invalid }
            stage = .resume
            try await reader.resume(audio)
            var audioOffset = audio.offset
            while audioOffset < manifest.audio.length {
                stage = .audioVerification
                let (bytes, prefixHash) = try await reader.chunk()
                stage = .acknowledgement
                try await sendChunk(bytes, offset: audioOffset, prefixHash: prefixHash, asset: .audio,
                                    descriptor: manifest.audio, operation: operation, entry: entry, sessionID: sessionID)
                audioOffset += UInt64(bytes.count)
            }
            var textHash = SHA256()
            stage = .resume
            let prefix = entry.transcript.prefix(Int(text.offset))
            textHash.update(data: prefix)
            guard Data(textHash.finalize()).base64EncodedString() == text.prefixSHA256 else { throw MeetingCopyWire.Failure.invalid }
            var textOffset = Int(text.offset)
            while textOffset < entry.transcript.count {
                let end = min(entry.transcript.count, textOffset + MeetingCopyWire.chunkLimit)
                let bytes = entry.transcript.subdata(in: textOffset..<end)
                textHash.update(data: bytes)
                stage = .acknowledgement
                try await sendChunk(bytes, offset: UInt64(textOffset),
                                    prefixHash: Data(textHash.finalize()).base64EncodedString(), asset: .transcript,
                                    descriptor: manifest.transcript, operation: operation, entry: entry, sessionID: sessionID)
                textOffset = end
            }
            stage = .audioVerification
            try await reader.verify(expected: manifest.audio, frozenIdentity: entry.sourceIdentity)
            var finalize = MeetingCopyWire.Message(.finalize)
            finalize.operation = operation
            stage = .finalReceipt
            let receipt = try await exchange(finalize, entry: entry, sessionID: sessionID)
            guard receipt.type == .committed else { throw MeetingCopyWire.Failure.invalid }
            try await save(receipt, entry: entry)
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
        } catch { throw MeetingCopyProblem(error, stage: stage) }
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
        do { try await repository.assertPending(id: entry.id) }
        catch { throw MeetingCopyProblem(error, stage: .snapshot) }
        guard client.transferSessionID == sessionID else { throw MeetingCopyProblem(code: .network) }
        let response = try await client.exchange(message)
        guard client.transferSessionID == sessionID, response.operation == message.operation else {
            throw MeetingCopyWire.Failure.invalid
        }
        if response.type == .failed { throw response.failure ?? MeetingCopyWire.Failure.invalid }
        return response
    }

    private func save(_ receipt: MeetingCopyWire.Message, entry: MeetingCopyOutbox.Entry) async throws {
        do {
            let expected = MeetingCopyWire.Operation(
                id: entry.id, meetingID: entry.meetingId.lowercased(),
                manifestSHA256: MeetingCopyWire.hash(entry.manifest)
            )
            guard receipt.type == .committed, receipt.receiptID != nil,
                  receipt.operation == expected else { throw MeetingCopyWire.Failure.invalid }
            try receipt.validate()
        } catch { throw MeetingCopyProblem(error, stage: .finalReceipt) }
        do {
            try await repository.recordReceipt(id: entry.id, manifest: entry.manifest, receipt: MeetingCopyWire.encode(receipt))
        } catch { throw MeetingCopyProblem(error, stage: .receiptSave) }
    }

    private struct Export: Sendable { let manifest: Data; let transcript: Data; let identity: Data }

    nonisolated private static func validateEntry(_ entry: MeetingCopyOutbox.Entry) async throws -> MeetingCopyWire.Manifest {
        let manifest = try MeetingCopyWire.decodeManifest(entry.manifest)
        guard manifest.meetingID == entry.meetingId.lowercased(),
              manifest.transcript.length == entry.transcript.count,
              manifest.transcript.sha256 == MeetingCopyWire.hash(entry.transcript) else { throw MeetingCopyWire.Failure.invalid }
        let transcript = try MeetingCopyWire.decode(MeetingCopyWire.Transcript.self, from: entry.transcript,
                                                    limit: MeetingCopyWire.transcriptLimit)
        try validateTranscript(transcript, manifest: manifest)
        let raw = try JSONDecoder().decode(MeetingCopyOutbox.Snapshot.self, from: entry.snapshot)
        let ids = try MeetingCopyOutbox.copyIdentifiers(in: raw, allowingLegacy: true)
        let expected: [MeetingCopyWire.Utterance] = zip(raw.utterances, ids).map { item, id in
            .init(id: id, startMs: Int64(item.startMs), endMs: Int64(item.endMs), text: item.text,
                  locale: item.localeIdentifier, revision: item.revision, source: item.engine.rawValue)
        }
        guard transcript.utterances == expected else { throw MeetingCopyWire.Failure.invalid }
        return manifest
    }

    nonisolated private static func makeExport(_ snapshot: MeetingCopyOutbox.Snapshot, store: AudioFileStore,
                                              allowingLegacy: Bool = false) async throws -> Export {
        var stage = MeetingCopyProblem.Stage.audioVerification
        do {
        let meeting = snapshot.meeting
        guard let fileName = meeting.audioFileName, let hex = meeting.audioSHA256,
              hex.utf8.count == 64,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let length = meeting.audioByteCount, length > 0 else { throw MeetingCopyProblem(code: .audioMismatch) }
        let digest = stride(from: 0, to: hex.count, by: 2).compactMap { index -> UInt8? in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        }
        guard digest.count == 32 else { throw MeetingCopyProblem(code: .audioMismatch) }
        let audio = MeetingCopyWire.Asset(length: UInt64(length), sha256: Data(digest).base64EncodedString())
        let reader = try MeetingCopyAudioReader(url: store.url(forFileName: fileName))
        do {
            try await reader.verify(expected: audio)
            let identity = try await reader.identityBytes()
            try await reader.close()
            stage = .transcriptValidation
            let ids = try MeetingCopyOutbox.copyIdentifiers(in: snapshot, allowingLegacy: allowingLegacy)
            let revision = UUID().uuidString.lowercased()
            let transcript = MeetingCopyWire.Transcript(revision: revision, parentRevision: nil, locale: meeting.localeIdentifier,
                utterances: zip(snapshot.utterances, ids).map { item, id in
                    .init(id: id, startMs: Int64(item.startMs), endMs: Int64(item.endMs),
                          text: item.text, locale: item.localeIdentifier, revision: item.revision, source: item.engine.rawValue)
                })
            let text = try MeetingCopyWire.encode(transcript)
            guard text.count <= MeetingCopyWire.transcriptLimit else { throw MeetingCopyProblem(code: .transcriptInvalid) }
            stage = .metadataValidation
            let manifest = MeetingCopyWire.Manifest(meetingID: meeting.id.lowercased(), title: meeting.title,
                startedAtMs: try milliseconds(meeting.startedAt), createdAtMs: try milliseconds(meeting.createdAt),
                updatedAtMs: try milliseconds(meeting.updatedAt), durationMs: Int64(meeting.durationMs),
                locale: meeting.localeIdentifier, audio: audio,
                transcript: .init(length: UInt64(text.count), sha256: MeetingCopyWire.hash(text)),
                transcriptRevision: revision, parentRevision: nil, source: "publishedLocalTranscript")
            do { try manifest.validate() }
            catch { throw MeetingCopyProblem(code: .metadataInvalid) }
            stage = .transcriptValidation
            try validateTranscript(transcript, manifest: manifest)
            let bytes = try MeetingCopyWire.encode(manifest)
            stage = .metadataValidation
            _ = try MeetingCopyWire.decodeManifest(bytes)
            return Export(manifest: bytes, transcript: text, identity: identity)
        } catch {
            try? await reader.close()
            throw error
        }
        } catch { throw MeetingCopyProblem(error, stage: stage) }
    }

    nonisolated static func validateTranscript(_ transcript: MeetingCopyWire.Transcript,
                                               manifest: MeetingCopyWire.Manifest) throws {
        guard transcript.utterances.count <= 100_000 else { throw MeetingCopyProblem(code: .transcriptInvalid) }
        var ids = Set<String>()
        var previous: Int64 = 0
        for item in transcript.utterances {
            guard MeetingCopyWire.validID(item.id), ids.insert(item.id).inserted else {
                throw MeetingCopyProblem(code: .transcriptIdentity)
            }
            guard item.startMs >= previous, item.endMs >= item.startMs, item.endMs <= manifest.durationMs else {
                throw MeetingCopyProblem(code: .transcriptTiming)
            }
            guard (1...Int(Int32.max)).contains(item.revision), ["appleSpeech", "nemotron"].contains(item.source) else {
                throw MeetingCopyProblem(code: .transcriptProvenance)
            }
            guard item.text.utf8.count <= 65_536, MeetingCopyWire.validLocale(item.locale) else {
                throw MeetingCopyProblem(code: .transcriptInvalid)
            }
            previous = item.startMs
        }
        do { try transcript.validate(manifest: manifest) }
        catch { throw MeetingCopyProblem(code: .transcriptInvalid) }
    }

    nonisolated private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value <= 253_402_300_799_999 else { throw MeetingCopyProblem(code: .metadataInvalid) }
        return Int64(value.rounded(.down))
    }
}
