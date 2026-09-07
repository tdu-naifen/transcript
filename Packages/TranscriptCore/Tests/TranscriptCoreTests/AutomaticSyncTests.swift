import AVFoundation
import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncTests {
    typealias Wire = AutomaticSyncWire

    private func configured(_ database: AppDatabase) async throws -> AutomaticSyncRepository {
        let sync = AutomaticSyncRepository(database)
        try await sync.configure(peerID: "peer", enabled: true)
        return sync
    }

    private func encodeAudioFixture(at url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.15 * sin(Float(index) * 2 * .pi * 440 / 16_000)
        }
        try file.write(from: buffer)
    }

    private func operation(_ field: String, _ value: String?, clock: Int64 = 1,
                           device: String = "a", id: String = UUID().uuidString,
                           entity: Wire.Entity = .meeting, entityID: String = "meeting") -> Wire.Operation {
        .init(stamp: .init(counter: clock, deviceID: device, operationID: id),
              entity: entity, entityID: entityID, field: field, value: value)
    }

    @Test func localTransactionRollsBackOutboxAndClock() async throws {
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        let before = try await sync.pending(peerID: "peer")
        enum Stop: Error { case rollback }
        await #expect(throws: Stop.rollback) {
            try await db.writer.write { database in
                try Meeting(title: "rollback", startedAt: Date(), originDeviceId: "local").insert(database)
                throw Stop.rollback
            }
        }
        #expect(try await sync.pending(peerID: "peer") == before)
        #expect(try await db.reader.read { try Int.fetchOne($0, sql: "SELECT counter FROM automaticSyncState") } == 0)
        let meeting = Meeting(title: "atomic", startedAt: Date(), originDeviceId: "local")
        try await MeetingRepository(db).insert(meeting)
        #expect(try await sync.pending(peerID: "peer").count == 6)
        try await MeetingRepository(db).rename(id: meeting.id, title: "edited", deviceId: "local")
        #expect(try await sync.pending(peerID: "peer").count == 7)
    }

    @Test func permutationsDuplicatesAndIndependentFieldsConverge() async throws {
        let operations = [
            operation("title", "old", clock: 1, device: "z", id: "old"),
            operation("title", "winner", clock: 9, device: "z", id: "winner"),
            operation("title", "loser", clock: 9, device: "a", id: "loser"),
            operation("emoji", "🎙️", clock: 4, device: "a", id: "emoji"),
            operation("title", "tie loser", clock: 9, device: "z", id: "a")
        ]
        for seed in 0..<32 {
            var generator = SeededSyncGenerator(state: UInt64(seed + 1))
            let db = try AppDatabase.inMemory()
            let sync = try await configured(db)
            for op in (operations + operations).shuffled(using: &generator) {
                try await sync.apply([op], from: "peer")
            }
            #expect(try await sync.values(entity: .meeting, id: "meeting") == ["title": "winner", "emoji": "🎙️"])
            #expect(try await sync.audit(entity: .meeting, id: "meeting").count == operations.count)
            #expect(try await sync.pending(peerID: "peer").isEmpty)
        }
    }

    @Test(arguments: ["é", "e\u{301}", "K", "", "a\0b", "has space", String(repeating: "a", count: 129)])
    func nonASCIIOrUnboundedStampIDsAreRejected(id: String) async throws {
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        for actor in [false, true] {
            let op = operation("title", "value", device: actor ? id : "actor", id: actor ? "operation" : id)
            await #expect(throws: Wire.Failure.invalid) { try await sync.apply([op], from: "peer") }
        }
        #expect(try await sync.audit(entity: .meeting, id: "meeting").isEmpty)
        let fragment = Wire.Fragment(operationID: id, offset: 0, total: 1, bytes: Data([1]))
        #expect(throws: Wire.Failure.invalid) { try Wire.decode(Wire.encode(Wire.Message(kind: .fragment, fragment: fragment))) }
        #expect(throws: Wire.Failure.invalid) { try Wire.decode(Wire.encode(Wire.Message(kind: .ack, operationID: id))) }
        // Legacy entity IDs are not stamp actors and retain their existing domain.
        let legacy = operation("title", "legacy", entityID: "é")
        try await sync.apply([legacy], from: "peer")
        #expect(try await sync.values(entity: .meeting, id: "é")["title"] == "legacy")
    }

    @Test(arguments: [("é", "e\u{301}"), ("Å", "A\u{30A}"), ("가", "\u{1100}\u{1161}")])
    func canonicalUnicodeTextConvergesAsExactBytesAcrossPermutations(forms: (String, String)) async throws {
        #expect(forms.0 == forms.1)
        #expect(Data(forms.0.utf8) != Data(forms.1.utf8))
        let sourceDB = try AppDatabase.inMemory()
        let source = try await configured(sourceDB)
        let meeting = Meeting(title: "seed", startedAt: Date(), originDeviceId: "source")
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1000, text: "seed", originDeviceId: "source")
        try await MeetingRepository(sourceDB).insert(meeting)
        try await UtteranceRepository(sourceDB).append(utterance)
        let baseline = try await source.pending(peerID: "peer", limit: 256)
        let clock = try #require(baseline.map(\.stamp.counter).max()) + 1
        for reverseForms in [false, true] {
            let winner = reverseForms ? forms.0 : forms.1
            let loser = reverseForms ? forms.1 : forms.0
            let operations = [
                operation("text", loser, clock: clock, device: "actor-A", id: "actor-loser", entity: .utterance, entityID: utterance.id),
                operation("text", loser, clock: clock, device: "actor-Z", id: "a-loser", entity: .utterance, entityID: utterance.id),
                operation("text", winner, clock: clock, device: "actor-Z", id: "z-winner", entity: .utterance, entityID: utterance.id),
                operation("title", loser, clock: clock, id: "a-title", entityID: meeting.id),
                operation("title", winner, clock: clock, id: "z-title", entityID: meeting.id)
            ]
            var expectedRevision: String?
            for seed in 0..<10 {
                var generator = SeededSyncGenerator(state: UInt64(seed + 1))
                let db = try AppDatabase.inMemory()
                let sync = try await configured(db)
                try await sync.apply(baseline, from: "peer")
                let delivery = seed == 0 ? operations : seed == 1 ? operations.reversed().map { $0 }
                    : (operations + operations).shuffled(using: &generator)
                for op in delivery { try await sync.apply([op], from: "peer") }
                let raw = try await db.reader.read { db in
                    (try Data.fetchOne(db, sql: "SELECT CAST(text AS BLOB) FROM utterance WHERE id=?", arguments: [utterance.id]),
                     try Data.fetchOne(db, sql: "SELECT CAST(title AS BLOB) FROM meeting WHERE id=?", arguments: [meeting.id]))
                }
                #expect(raw.0 == Data(winner.utf8))
                #expect(raw.1 == Data(winner.utf8))
                #expect(try await sync.values(entity: .utterance, id: utterance.id)["text"].map { Data($0.utf8) } == Data(winner.utf8))
                let revision = try await sync.transcriptRevision(meetingID: meeting.id)
                if let expectedRevision { #expect(revision == expectedRevision) }
                else { expectedRevision = revision }
                var equivocation = operations[2]
                equivocation.value = loser
                #expect(equivocation == operations[2])
                #expect(try Wire.encode(equivocation) != Wire.encode(operations[2]))
                await #expect(throws: Wire.Failure.equivocation) { try await sync.apply([equivocation], from: "peer") }
                await #expect(throws: Wire.Failure.equivocation) {
                    for fragment in try Wire.fragments(for: equivocation) {
                        _ = try await sync.receive(fragment, from: "peer")
                    }
                }
                #expect(try await sync.transcriptRevision(meetingID: meeting.id) == revision)
                #expect(try await sync.audit(entity: .utterance, id: utterance.id).filter { $0.id == equivocation.id }.count == 1)
            }
        }
    }

    @Test func importedLibraryRelaysOriginalOperationsWithIndependentPeerConsentAndAcknowledgements() async throws {
        let phoneDB = try AppDatabase.inMemory(), macDB = try AppDatabase.inMemory(), replacementDB = try AppDatabase.inMemory()
        let phone = AutomaticSyncRepository(phoneDB), mac = AutomaticSyncRepository(macDB)
        let replacement = AutomaticSyncRepository(replacementDB)
        try await phone.configure(peerID: "Mac", enabled: true, voiceprints: .allowed)
        try await mac.configure(peerID: "A", enabled: true, voiceprints: .allowed)
        try await mac.configure(peerID: "B", enabled: true)
        try await mac.configure(peerID: "C", enabled: true, voiceprints: .allowed)
        try await replacement.configure(peerID: "Mac", enabled: true)
        let meeting = Meeting(title: "Existing phone library", startedAt: Date(), originDeviceId: "A")
        try await MeetingRepository(phoneDB).insert(meeting)
        let speaker = Speaker(displayName: "Private identity", anonymousName: "Fox", colorIndex: 0, originDeviceId: "A")
        try await SpeakerRepository(phoneDB).upsert(speaker)
        let audio = Wire.Resource(kind: .audio, meetingID: meeting.id, sha256: String(repeating: "a", count: 64), byteCount: 32)
        let vector = Wire.Resource(kind: .voiceprint, speakerID: speaker.id, sha256: String(repeating: "b", count: 64),
                                   byteCount: 8, dimensions: 2, sampleCount: 7)
        let audioID = try await phone.registerResource(audio)
        let vectorID = try await phone.registerResource(vector)
        let original = try await phone.pending(peerID: "Mac", limit: 256)
        try await mac.apply(original, from: "A")
        #expect(try await mac.pending(peerID: "A").isEmpty)
        #expect(try await mac.status(peerID: "A").pendingCount == 0)
        let publicOperations = original.filter { !$0.biometric }
        #expect(try Wire.encode(await mac.pending(peerID: "B", limit: 256)) == Wire.encode(publicOperations))
        #expect(try await mac.status(peerID: "B").pendingCount == publicOperations.count)
        let privateOperation = try #require(original.first(where: { $0.biometric }))
        await #expect(throws: Wire.Failure.invalid) {
            try await mac.acknowledge(peerID: "B", operationIDs: [privateOperation.id])
        }
        await #expect(throws: Wire.Failure.invalid) {
            try await mac.acknowledge(peerID: "A", operationIDs: [original[0].id])
        }
        await #expect(throws: Wire.Failure.consentRequired) {
            try await replacement.apply([privateOperation], from: "Mac")
        }
        try await mac.setVoiceprintConsent(peerID: "B", state: .allowed)
        try await replacement.setVoiceprintConsent(peerID: "Mac", state: .allowed)
        let relayed = try await mac.pending(peerID: "B", limit: 256)
        #expect(try Wire.encode(relayed) == Wire.encode(original))
        #expect(try await mac.status(peerID: "B").pendingCount == original.count)
        #expect(try Wire.encode(await mac.pending(peerID: "B", limit: 256, includeBiometrics: false)) == Wire.encode(publicOperations))
        try await replacement.apply(relayed, from: "Mac")
        #expect(try await MeetingRepository(replacementDB).fetch(id: meeting.id)?.title == meeting.title)
        #expect(try await replacement.resource(id: audioID) == audio)
        #expect(try await replacement.resource(id: vectorID) == vector)
        #expect(try await replacement.pending(peerID: "Mac").isEmpty)
        try await mac.acknowledge(peerID: "B", operationIDs: relayed.map(\.id))
        #expect(try await mac.pending(peerID: "B").isEmpty)
        #expect(try await mac.status(peerID: "B").pendingCount == 0)
        #expect(try Wire.encode(await mac.pending(peerID: "C", limit: 256)) == Wire.encode(original))
        #expect(try await mac.status(peerID: "C").pendingCount == original.count)
        #expect(try await mac.pending(peerID: "A").isEmpty)
        for op in original { #expect(try await mac.receivedFrom(operationID: op.id) == "A") }
        #expect(try await macDB.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM automaticSyncOperation") } == original.count)
    }

    @Test func roundTripMaterializesSearchProvenanceAndNoEcho() async throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await configured(a), right = try await configured(b)
        try await left.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await right.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let meeting = Meeting(title: "Shared title", startedAt: Date(), durationMs: 1000, originDeviceId: "source")
        try await MeetingRepository(a).insert(meeting)
        let speaker = Speaker(displayName: "Ada", anonymousName: "Fox", colorIndex: 1, originDeviceId: "source")
        try await SpeakerRepository(a).upsert(speaker)
        try await SpeakerRepository(a).assignDisplayIndex(meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: "source")
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1000, text: "Original words",
                                  speakerId: speaker.id, engine: .nemotron, revision: 3, originDeviceId: "source")
        try await UtteranceRepository(a).append(utterance)
        let outgoing = try await left.pending(peerID: "peer", limit: 256)
        for op in outgoing.reversed() { try await right.apply([op], from: "peer") }
        #expect(try await MeetingRepository(b).fetch(id: meeting.id)?.title == meeting.title)
        let received = try #require(try await UtteranceRepository(b).fetch(meetingId: meeting.id).first)
        #expect(received.id == utterance.id && received.text == utterance.text && received.engine == .nemotron)
        #expect(received.revision == 3 && received.speakerId == speaker.id)
        #expect(try await SpeakerRepository(b).speakers(inMeeting: meeting.id).count == 1)
        #expect(try await right.transcriptRevision(meetingID: meeting.id) == left.transcriptRevision(meetingID: meeting.id))
        #expect(try await right.pending(peerID: "peer").isEmpty)
        let indexed = try await b.reader.read { try String.fetchAll($0, sql: "SELECT text FROM searchDocument WHERE meetingId=?", arguments: [meeting.id]) }
        #expect(indexed.contains("Original words") && indexed.contains("Shared title"))
        try await left.acknowledge(peerID: "peer", operationIDs: outgoing.map(\.id))
        #expect(try await left.pending(peerID: "peer").isEmpty)
        try await MeetingRepository(b).rename(id: meeting.id, title: "Reply", deviceId: "b")
        let reply = try await right.pending(peerID: "peer")
        #expect(reply.count == 1)
        #expect(try #require(reply.first).stamp.counter > outgoing.map(\.stamp.counter).max()!)
        try await left.apply(reply, from: "peer")
        #expect(try await MeetingRepository(a).fetch(id: meeting.id)?.title == "Reply")
    }

    @Test func deleteSurvivesRestartAndStaleChildArrival() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let deletion = Wire.Operation(stamp: .init(counter: 1, deviceID: "a", operationID: "delete"),
                                      entity: .meeting, entityID: "meeting", field: "", value: nil, isDelete: true)
        do {
            let db = try AppDatabase.onDisk(directory: directory)
            let sync = try await configured(db)
            try await sync.apply([deletion], from: "peer")
        }
        let reopened = try AppDatabase.onDisk(directory: directory)
        let sync = AutomaticSyncRepository(reopened)
        try await sync.apply([
            operation("title", "resurrect", clock: 999),
            operation("meetingId", "meeting", clock: 1000, entity: .utterance, entityID: "child")
        ], from: "peer")
        #expect(try await sync.isDeleted(entity: .meeting, id: "meeting"))
        #expect(try await sync.isDeleted(entity: .utterance, id: "child"))
        #expect(try await sync.values(entity: .meeting, id: "meeting").isEmpty)
        await #expect(throws: (any Error).self) {
            try await MeetingRepository(reopened).insert(Meeting(id: "meeting", title: "No", startedAt: Date(), originDeviceId: "a"))
        }
    }

    @Test func handshakeRequiresExplicitBiometricWillingness() throws {
        for kind in [Wire.Message.Kind.hello, .accepted] {
            for allowed in [false, true] {
                let message = Wire.Message(kind: kind, capability: Wire.capability, voiceprintsAllowed: allowed)
                let encoded = try Wire.encode(message)
                #expect(try Wire.decode(encoded).voiceprintsAllowed == allowed)
                var missing = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                missing.removeValue(forKey: "voiceprintsAllowed")
                let withoutPermission = try JSONSerialization.data(withJSONObject: missing, options: [.sortedKeys, .withoutEscapingSlashes])
                #expect(throws: (any Error).self) { try Wire.decode(withoutPermission) }
            }
        }
    }

    @Test func directionalPermissionCannotOverrideLocalConsent() async throws {
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        let op = operation("displayName", "Identity", entity: .speaker, entityID: "speaker")
        let fragments = try Wire.fragments(for: op)
        #expect(fragments.count == 1)
        await #expect(throws: Wire.Failure.consentRequired) {
            try await sync.receive(fragments[0], from: "peer", includeBiometrics: true)
        }
        try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
        await #expect(throws: Wire.Failure.consentRequired) {
            try await sync.receive(fragments[0], from: "peer", includeBiometrics: false)
        }
        #expect(try await sync.audit(entity: .speaker, id: "speaker").isEmpty)
        #expect(try await sync.receive(fragments[0], from: "peer", includeBiometrics: true) == op.id)
    }

    @Test func pausingOrDenyingPurgesIncompleteMetadataButRetainsCommittedValues() async throws {
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let committed = operation("displayName", "Retained", entity: .speaker, entityID: "speaker")
        try await sync.apply([committed], from: "peer")
        let incoming = operation("displayName", String(repeating: "sensitive", count: 800),
                                 clock: 2, entity: .speaker, entityID: "speaker")
        let fragments = try Wire.fragments(for: incoming)
        #expect(fragments.allSatisfy { $0.bytes.count <= 512 })
        #expect(fragments.reduce(into: Data()) { $0.append($1.bytes) } == (try Wire.encode(incoming)))
        for state in [Wire.Consent.paused, .denied, .revoked] {
            try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
            #expect(try await sync.receive(fragments[0], from: "peer") == nil)
            #expect(try await db.reader.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM automaticSyncFragment")
            } == 1)
            try await sync.setVoiceprintConsent(peerID: "peer", state: state)
            #expect(try await db.reader.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM automaticSyncFragment")
            } == 0)
            #expect(try await sync.values(entity: .speaker, id: "speaker")["displayName"] == "Retained")
            try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
            await #expect(throws: Wire.Failure.invalid) {
                try await sync.receive(fragments[1], from: "peer")
            }
        }
    }

    @Test func fragmentsPersistAcrossRestartAndRejectEquivocation() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let op = operation("title", String(repeating: "text", count: 4000))
        let fragments = try Wire.fragments(for: op)
        do {
            let db = try AppDatabase.onDisk(directory: directory)
            let sync = try await configured(db)
            #expect(try await sync.receive(fragments[0], from: "peer") == nil)
        }
        let sync = AutomaticSyncRepository(try AppDatabase.onDisk(directory: directory))
        for fragment in fragments {
            let result = try await sync.receive(fragment, from: "peer")
            #expect(result == (fragment == fragments.last ? op.id : nil))
        }
        for fragment in fragments { _ = try await sync.receive(fragment, from: "peer") }
        #expect(try await sync.audit(entity: .meeting, id: "meeting").count == 1)
        var forged = op
        forged.value = "changed"
        await #expect(throws: Wire.Failure.equivocation) { try await sync.apply([forged], from: "peer") }
    }

    @Test func resourceNamespacesConsentHashAndStalePublication() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.inMemory(), remote = try AppDatabase.inMemory()
        let sync = try await configured(db), receiver = try await configured(remote)
        let speaker = Speaker(anonymousName: "Fox", colorIndex: 1, originDeviceId: "a")
        try await SpeakerRepository(db).upsert(speaker)
        let bytes = Data([0, 0, 0, 0])
        let digest = IncrementalSHA256.hex(SHA256.hash(data: bytes))
        var voice = Wire.Resource(kind: .voiceprint, speakerID: speaker.id, sha256: digest, byteCount: 4,
                                  modelFingerprint: "model-a", preprocessing: "pcm16k-v1", dimensions: 1)
        let voiceID = try await sync.registerResource(voice)
        voice.modelFingerprint = "model-b"
        #expect(try AutomaticSyncRepository.resourceID(voice) != voiceID)
        voice.modelFingerprint = "model-a"
        voice.preprocessing = "pcm48k-v2"
        #expect(try AutomaticSyncRepository.resourceID(voice) != voiceID)
        voice.dimensions = 2
        #expect(throws: Wire.Failure.invalid) { try AutomaticSyncRepository.resourceID(voice) }
        #expect(try await sync.pending(peerID: "peer").allSatisfy { !$0.biometric })
        try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let biometric = try #require(try await sync.pending(peerID: "peer").first(where: { $0.entity == .resource && $0.biometric }))
        await #expect(throws: Wire.Failure.consentRequired) { try await receiver.apply([biometric], from: "peer") }
        try await receiver.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await receiver.apply([biometric], from: "peer")
        try await receiver.setVoiceprintConsent(peerID: "peer", state: .paused)
        #expect(try await receiver.resource(id: voiceID) != nil)
        try await receiver.setVoiceprintConsent(peerID: "peer", state: .revoked)
        #expect(try await receiver.resource(id: voiceID) == nil)
        let meeting = Meeting(title: "Input", startedAt: Date(), originDeviceId: "a")
        try await MeetingRepository(db).insert(meeting)
        let input = try await sync.transcriptRevision(meetingID: meeting.id)
        let draft = AnalysisResultDraft(meetingId: meeting.id, kind: .qa, payloadJSON: "{\"answer\":\"Verified\"}", producedByDeviceId: "mac")
        let artifactBytes = try Wire.encode(draft)
        let artifactDigest = IncrementalSHA256.hex(SHA256.hash(data: artifactBytes))
        let artifact = Wire.Resource(kind: .analysis, meetingID: meeting.id, sha256: artifactDigest, byteCount: Int64(artifactBytes.count),
                                     modelFingerprint: "model-a", preprocessing: "v1", inputRevision: input)
        let resourceID = try await sync.registerResource(artifact)
        let source = directory.appendingPathComponent("source")
        try Data([1, 2, 3, 4]).write(to: source)
        await #expect(throws: Wire.Failure.hashMismatch) { try await sync.installResource(id: resourceID, from: source, directory: directory.appendingPathComponent("resources")) }
        try artifactBytes.write(to: source)
        _ = try await sync.installResource(id: resourceID, from: source, directory: directory.appendingPathComponent("resources"))
        try await sync.publishResource(id: resourceID)
        #expect(try await sync.publishedResource(meetingID: meeting.id, kind: .analysis) == resourceID)
        #expect(try await AnalysisResultRepository(db).latest(meetingId: meeting.id, kind: .qa)?.payloadJSON == draft.payloadJSON)
        try await UtteranceRepository(db).append(Utterance(meetingId: meeting.id, startMs: 0, endMs: 1, text: "new input", originDeviceId: "a"))
        await #expect(throws: Wire.Failure.staleRevision) { try await sync.publishResource(id: resourceID) }
        #expect(try await sync.publishedResource(meetingID: meeting.id, kind: .analysis) == nil)
        #expect(try await AnalysisResultRepository(db).latest(meetingId: meeting.id, kind: .qa) == nil)
    }

    @Test func wireRejectsUnknownKeysAndOversizedFragments() throws {
        let hello = Wire.Message(kind: .hello, capability: Wire.capability)
        let encoded = try Wire.encode(hello)
        #expect(try Wire.decode(encoded).kind == .hello)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unexpected"] = true
        #expect(throws: Wire.Failure.invalid) { try Wire.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
        let fragment = Wire.Fragment(operationID: "op", offset: 0, total: 769, bytes: Data(repeating: 0, count: 769))
        #expect(throws: Wire.Failure.invalid) { try Wire.decode(Wire.encode(Wire.Message(kind: .fragment, fragment: fragment))) }
        let traversal = AutomaticSyncResourceWire.Message(kind: .request, resourceID: "../outside", offset: 0)
        #expect(throws: Wire.Failure.invalid) { try AutomaticSyncResourceWire.decode(Wire.encode(traversal)) }
    }

    @Test func revokeRemovesFilesButPreservesIndependentPeerContributions() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await sync.configure(peerID: "other", enabled: true, voiceprints: .allowed)
        let bytes = Data([0, 0, 0, 0])
        let descriptor = Wire.Resource(kind: .voiceprint, speakerID: "speaker",
                                       sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)), byteCount: 4,
                                       modelFingerprint: "model", preprocessing: "16k", dimensions: 1)
        let id = try AutomaticSyncRepository.resourceID(descriptor)
        var op = operation("descriptor", String(decoding: try Wire.encode(descriptor), as: UTF8.self),
                           entity: .resource, entityID: id)
        op.biometric = true
        try await sync.apply([op], from: "peer")
        try await sync.apply([op], from: "other")
        #expect(try await sync.receivedFrom(operationID: op.id) == "peer")
        #expect(try await sync.resourceSources(id: id) == ["other", "peer"])
        let source = directory.appendingPathComponent("vector")
        try bytes.write(to: source)
        let installed = try await sync.installResource(id: id, from: source, directory: directory.appendingPathComponent("resources"))
        try await sync.setVoiceprintConsent(peerID: "peer", state: .revoked)
        #expect(try await sync.resource(id: id) != nil)
        #expect(FileManager.default.fileExists(atPath: installed.path))
        try await sync.setVoiceprintConsent(peerID: "other", state: .revoked)
        #expect(try await sync.resource(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await sync.apply([op], from: "peer")
        #expect(try await sync.resource(id: id) == descriptor)
    }

    @Test func repositoryArtifactCaptureIsAtomicAndInputBound() async throws {
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        let meeting = Meeting(title: "Derive", startedAt: Date(), originDeviceId: "a")
        try await MeetingRepository(db).insert(meeting)
        let revision = try await sync.transcriptRevision(meetingID: meeting.id)
        let repository = AnalysisResultRepository(db)
        let result = AnalysisResultDraft(meetingId: meeting.id, kind: .qa, payloadJSON: "{}", producedByDeviceId: "mac")
        try await repository.record(result, inputRevision: revision, modelFingerprint: "model-sha", preprocessing: "v1")
        let pending = try await sync.pending(peerID: "peer")
        let artifact = try #require(pending.first(where: { $0.entity == .resource }))
        #expect(try await sync.resourceBytes(id: artifact.entityID, for: "peer") == Wire.encode(result))
        #expect(try await repository.latest(meetingId: meeting.id, kind: .qa)?.id == result.id)
        try await UtteranceRepository(db).append(Utterance(meetingId: meeting.id, startMs: 0, endMs: 1, text: "Changed", originDeviceId: "a"))
        let before = try await sync.pending(peerID: "peer")
        await #expect(throws: Wire.Failure.staleRevision) {
            try await repository.record(AnalysisResultDraft(meetingId: meeting.id, kind: .qa, payloadJSON: "stale", producedByDeviceId: "mac"),
                                        inputRevision: revision, modelFingerprint: "model-sha", preprocessing: "v1")
        }
        #expect(try await sync.pending(peerID: "peer") == before)
        #expect(try await repository.fetchAll(meetingId: meeting.id).count == 1)
        #expect(try await repository.latest(meetingId: meeting.id, kind: .qa) == nil)
    }

    @Test func removeWinsAssociationAndMeetingDeleteInEveryOrder() async throws {
        let source = try AppDatabase.inMemory()
        let sync = try await configured(source)
        try await sync.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let meeting = Meeting(title: "Remove", startedAt: Date(), originDeviceId: "source")
        let speaker = Speaker(anonymousName: "Fox", colorIndex: 1, originDeviceId: "source")
        try await MeetingRepository(source).insert(meeting)
        try await SpeakerRepository(source).upsert(speaker)
        try await SpeakerRepository(source).assignDisplayIndex(meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: "source")
        let initial = try await sync.pending(peerID: "peer")
        try await source.writer.write { db in
            try db.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId=?", arguments: [meeting.id])
        }
        let changes = try await sync.pending(peerID: "peer")
        let associationID = try #require(initial.first(where: { $0.entity == .association })?.entityID)
        for seed in 1...8 {
            var generator = SeededSyncGenerator(state: UInt64(seed))
            let target = try AppDatabase.inMemory()
            let remote = try await configured(target)
            try await remote.setVoiceprintConsent(peerID: "peer", state: .allowed)
            for op in changes.shuffled(using: &generator) { try await remote.apply([op], from: "peer") }
            #expect(try await remote.isDeleted(entity: .association, id: associationID))
            #expect(try await SpeakerRepository(target).speakers(inMeeting: meeting.id).isEmpty)
            #expect(try await MeetingRepository(target).fetch(id: meeting.id) != nil)
            #expect(try await remote.pending(peerID: "peer").isEmpty)
        }
        try await MeetingRepository(source).delete(id: meeting.id)
        #expect(try await sync.isDeleted(entity: .meeting, id: meeting.id))
        #expect(try await SpeakerRepository(source).fetch(id: speaker.id) != nil)
    }

    @Test func failedRemoteBatchRollsBackProjectionReceiptsAndSuppression() async throws {
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        let op = operation("title", "accepted", id: "same")
        try await sync.apply([op], from: "peer")
        let changed = operation("title", "forged", id: "same")
        await #expect(throws: Wire.Failure.equivocation) {
            try await sync.apply([operation("emoji", "🎙", clock: 9), changed], from: "peer")
        }
        #expect(try await sync.values(entity: .meeting, id: "meeting") == ["title": "accepted"])
        let suppression = try await db.reader.read { try Int.fetchOne($0, sql: "SELECT applying FROM automaticSyncState") }
        #expect(suppression == 0)
        try await MeetingRepository(db).insert(Meeting(title: "Still captures", startedAt: Date(), originDeviceId: "local"))
        #expect(try await sync.pending(peerID: "peer").count == 6)
        try await sync.configure(peerID: "peer", enabled: false)
        await #expect(throws: Wire.Failure.disabled) { try await sync.pending(peerID: "peer") }
        await #expect(throws: Wire.Failure.disabled) { try await sync.apply([op], from: "peer") }
    }

    @Test func seededMultiReplicaMutationAndReorderConverges() async throws {
        for seed in 1...6 {
            var random = SeededSyncGenerator(state: UInt64(seed))
            let databases = try (0..<3).map { _ in try AppDatabase.inMemory() }
            var replicas: [AutomaticSyncRepository] = []
            for db in databases { replicas.append(try await configured(db)) }
            let meeting = Meeting(title: "Genesis", startedAt: Date(), originDeviceId: "source")
            try await MeetingRepository(databases[0]).insert(meeting)
            let genesis = try await replicas[0].pending(peerID: "peer")
            for replica in replicas.dropFirst() { try await replica.apply(genesis, from: "peer") }
            for round in 0..<40 {
                let index = Int(random.next() % 3)
                try await MeetingRepository(databases[index]).rename(id: meeting.id, title: "seed-\(seed)-\(round)", deviceId: "local")
                if round % 3 == 0 {
                    let target = (index + 1) % 3
                    let pending = try await replicas[index].pending(peerID: "peer", limit: 256)
                    try await replicas[target].apply(pending.shuffled(using: &random), from: "peer")
                }
            }

            var operations: [Wire.Operation] = []
            for replica in replicas { operations += try await replica.pending(peerID: "peer", limit: 256) }
            let expected = try #require(operations.filter { $0.field == "title" }.max(by: { $0.stamp < $1.stamp })?.value)
            for (index, replica) in replicas.enumerated() {
                for operation in operations.shuffled(using: &random) { try await replica.apply([operation], from: "peer") }
                #expect(try await MeetingRepository(databases[index]).fetch(id: meeting.id)?.title == expected)
            }
            try await MeetingRepository(databases[0]).delete(id: meeting.id)
            let tombstone = try #require(try await replicas[0].pending(peerID: "peer").first(where: \.isDelete))
            for (index, replica) in replicas.enumerated() {
                for operation in (operations + [tombstone]).shuffled(using: &random) { try await replica.apply([operation], from: "peer") }
                #expect(try await MeetingRepository(databases[index]).fetch(id: meeting.id) == nil)
            }
        }
    }

    @Test func resourceTransferResumesVerifiedPrefixAndPublishesAudioWithoutRewrite() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioDirectory = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let sourceFile = audioDirectory.appendingPathComponent("sealed.m4a")
        try encodeAudioFixture(at: sourceFile)
        let audio = try Data(contentsOf: sourceFile)
        #expect(audio.count > 768 && audio.count < 100_000)
        let hash = IncrementalSHA256.hex(SHA256.hash(data: audio))
        let sourceDB = try AppDatabase.inMemory()
        let source = try await configured(sourceDB)
        let meeting = Meeting(title: "Audio", startedAt: Date(), durationMs: 1000, audioFileName: "sealed.m4a",
                              audioSHA256: hash, audioByteCount: audio.count, state: .recorded, originDeviceId: "source")
        try await MeetingRepository(sourceDB).insert(meeting)
        let operations = try await source.pending(peerID: "peer")
        let resourceID = try #require(operations.first(where: { $0.entity == .resource })?.entityID)
        let sender = AutomaticSyncResourceTransfer(sourceDB, directory: audioDirectory)
        let receivingRoot = directory.appendingPathComponent("received")
        let dbRoot = directory.appendingPathComponent("database")
        let first = try #require(try await sender.chunk(resourceID: resourceID, offset: 0, for: "peer", audioDirectory: audioDirectory))
        do {
            let targetDB = try AppDatabase.onDisk(directory: dbRoot)
            let target = try await configured(targetDB)
            try await target.apply(operations, from: "peer")
            let transfer = AutomaticSyncResourceTransfer(targetDB, directory: receivingRoot, quotaBytes: Int64(audio.count * 3))
            #expect(try await transfer.receive(first, from: "peer") == 768)
        }
        let reopened = try AppDatabase.onDisk(directory: dbRoot)
        let target = AutomaticSyncRepository(reopened)
        let transfer = AutomaticSyncResourceTransfer(reopened, directory: receivingRoot, quotaBytes: Int64(audio.count * 3))
        #expect(try await transfer.progress(resourceID: resourceID, from: "peer") == 768)
        #expect(try await transfer.receive(first, from: "peer") == 768)
        var offset: Int64 = 768
        var last = first
        while let chunk = try await sender.chunk(resourceID: resourceID, offset: offset, for: "peer", audioDirectory: audioDirectory) {
            offset = try await transfer.receive(chunk, from: "peer")
            last = chunk
        }
        #expect(offset == audio.count)
        #expect(try await transfer.receive(last, from: "peer") == audio.count)
        #expect(try await target.verifiedAudioImports().isEmpty)
        try await target.adoptAudioResource(id: resourceID)
        let imports = try await target.verifiedAudioImports()
        #expect(imports.count == 1)
        #expect(imports.first?.meetingID == meeting.id && imports.first?.audioSHA256 == hash)
        let restarted = AutomaticSyncRepository(try AppDatabase.onDisk(directory: dbRoot))
        #expect(try await restarted.verifiedAudioImports() == imports)
        let received = try #require(try await MeetingRepository(reopened).fetch(id: meeting.id))
        #expect(received.audioSHA256 == hash)
        #expect(received.audioByteCount == audio.count && received.state == .recorded)
        let audioStore = AudioFileStore(directory: receivingRoot)
        let receivedName = try #require(received.audioFileName)
        let playbackURL = try audioStore.url(forFileName: receivedName)
        #expect(audioStore.exists(fileName: receivedName))
        #expect(imports.first?.fileURL == playbackURL)
        #expect(try Data(contentsOf: playbackURL) == audio)
        #expect(try Data(contentsOf: sourceFile) == audio)
        let decoded = try AVAudioFile(forReading: playbackURL)
        #expect(decoded.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(try AVAudioFile(forReading: sourceFile).length == decoded.length)
        let decodedBuffer = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_000))
        try decoded.read(into: decodedBuffer)
        let decodedSamples = try #require(decodedBuffer.floatChannelData?[0])
        #expect(decodedBuffer.frameLength > 0)
        #expect((0..<Int(decodedBuffer.frameLength)).contains { abs(decodedSamples[$0]) > 0.01 })
        try await target.setVoiceprintConsent(peerID: "peer", state: .revoked)
        #expect(try await target.resourceSources(id: resourceID) == ["peer"])
        #expect(try await target.verifiedAudioImports() == imports)
        #expect(try await target.pending(peerID: "peer").isEmpty)
        let partials = try FileManager.default.contentsOfDirectory(atPath: receivingRoot.path).filter { $0.hasPrefix(".partial-") }
        #expect(partials.isEmpty)
    }

    @Test func voiceprintChunksMaterializeMatchingWithRecordedReplicaProvenance() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDB = try AppDatabase.inMemory(), targetDB = try AppDatabase.inMemory()
        let source = try await configured(sourceDB), target = try await configured(targetDB)
        for repository in [source, target] {
            try await repository.setVoiceprintConsent(peerID: "peer", state: .allowed)
        }
        let speaker = Speaker(displayName: "Fixture", anonymousName: "Fox", originDeviceId: "fixture")
        try await SpeakerRepository(sourceDB).upsert(speaker)
        let embedding = SpeakerEmbedding(speakerId: speaker.id, floats: [0.6, 0.8],
            originDeviceId: "fixture", modelIdentifier: "fixture-model-v1", preprocessing: "fixture-pcm-v1")
        try await SpeakerRepository(sourceDB).addEmbedding(embedding)
        let operations = try await source.pending(peerID: "peer")
        let resource = try #require(operations.first { $0.entity == .resource })
        try await target.apply(operations.reversed(), from: "peer")
        let sender = AutomaticSyncResourceTransfer(sourceDB, directory: directory.appendingPathComponent("source"))
        let receiver = AutomaticSyncResourceTransfer(targetDB, directory: directory.appendingPathComponent("received"))
        let chunk = try #require(try await sender.chunk(resourceID: resource.entityID, offset: 0, for: "peer"))
        let message = AutomaticSyncResourceWire.Message(kind: .chunk, chunk: chunk)
        let decoded = try AutomaticSyncResourceWire.decode(Wire.encode(message))
        #expect(try await receiver.receive(try #require(decoded.chunk), from: "peer") == embedding.vector.count)
        try await target.adoptVoiceprintResource(id: resource.entityID)
        let adopted = try #require(try await SpeakerRepository(targetDB).embeddings(forSpeaker: speaker.id).first)
        #expect(adopted.vector == embedding.vector)
        #expect(adopted.originDeviceId == resource.stamp.deviceID)
        #expect(try await source.deviceID() == adopted.originDeviceId)
        let matcher = VoiceprintMatcher(speakers: SpeakerRepository(targetDB),
            modelIdentifier: "fixture-model-v1", preprocessing: "fixture-pcm-v1")
        guard case .matched(let matched, _) = try await matcher.match(embedding: [0.6, 0.8], cleanDuration: 3) else {
            Issue.record("Verified compatible fixture must enter the actual matcher")
            return
        }
        #expect(matched == speaker.id)
        #expect(try await target.pending(peerID: "peer").isEmpty)
    }

    @Test func resourceQuotaAndCorruptionAreRejectedBeforePublication() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.inMemory()
        let sync = try await configured(db)
        let bytes = Data(repeating: 3, count: 1024)
        let descriptor = Wire.Resource(kind: .audio, meetingID: "meeting",
                                       sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)), byteCount: 1024)
        let id = try await sync.registerResource(descriptor)
        let first = AutomaticSyncResourceWire.Chunk(resourceID: id, offset: 0, total: 1024, bytes: bytes.prefix(768))
        let limited = AutomaticSyncResourceTransfer(db, directory: directory, quotaBytes: 100)
        await #expect(throws: Wire.Failure.resourceUnavailable) { try await limited.receive(first, from: "peer") }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let transfer = AutomaticSyncResourceTransfer(db, directory: directory, quotaBytes: 4096)
        _ = try await transfer.receive(first, from: "peer")
        let damaged = AutomaticSyncResourceWire.Chunk(resourceID: id, offset: 768, total: 1024, bytes: Data(repeating: 9, count: 256))
        await #expect(throws: Wire.Failure.hashMismatch) { try await transfer.receive(damaged, from: "peer") }
        #expect(try await transfer.progress(resourceID: id, from: "peer") == 768)
        let final = AutomaticSyncResourceWire.Chunk(resourceID: id, offset: 768, total: 1024, bytes: bytes.suffix(256))
        #expect(try await transfer.receive(final, from: "peer") == 1024)
        #expect(try Data(contentsOf: directory.appendingPathComponent(descriptor.sha256 + ".m4a")) == bytes)
    }
}

private struct SeededSyncGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
