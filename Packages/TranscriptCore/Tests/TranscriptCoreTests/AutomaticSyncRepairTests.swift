import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncRepairTests {
    typealias Wire = AutomaticSyncWire

    private func sync(_ db: AppDatabase, consent: Wire.Consent = .allowed) async throws -> AutomaticSyncRepository {
        let repo = AutomaticSyncRepository(db)
        try await repo.configure(peerID: "peer", enabled: true, voiceprints: consent)
        return repo
    }

    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".sync-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exchange(_ source: AutomaticSyncRepository, _ target: AutomaticSyncRepository) async throws {
        while true {
            let operations = try await source.pending(peerID: "peer", limit: 256)
            if operations.isEmpty { return }
            try await target.apply(operations, from: "peer")
            try await source.acknowledge(peerID: "peer", operationIDs: operations.map(\.id))
        }
    }

    @Test func v11NULBaselineAndFollowingEditsPreserveExactUTF8() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v11_liveSpeakerEvidence")
        let meeting = Meeting(title: "legacy title", startedAt: Date(), originDeviceId: "v11")
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 5,
                                  text: "before\0after 🦊", originDeviceId: "v11")
        try await queue.write { db in
            try meeting.insert(db)
            try utterance.insert(db)
            try db.execute(sql: "UPDATE utterance SET text=CAST(? AS TEXT) WHERE id=?",
                           arguments: [Data(utterance.text.utf8), utterance.id])
        }
        let upgraded = try AppDatabase(queue)
        let other = try AppDatabase.inMemory()
        let left = try await sync(upgraded), right = try await sync(other)
        #expect(try await upgraded.reader.read {
            try Data.fetchOne($0, sql: "SELECT CAST(text AS BLOB) FROM utterance WHERE id=?", arguments: [utterance.id])
        } == Data(utterance.text.utf8))
        try await exchange(left, right)
        #expect(try await UtteranceRepository(other).fetch(meetingId: meeting.id).first?.text == utterance.text)
        let edited = "edited\0middle\0tail"
        try await upgraded.writer.write { db in
            try db.execute(sql: "UPDATE utterance SET text=CAST(? AS TEXT) WHERE id=?", arguments: [Data(edited.utf8), utterance.id])
        }
        let pending = try await left.pending(peerID: "peer")
        #expect(pending.first?.value == edited)
        for operation in pending {
            for fragment in try Wire.fragments(for: operation) { _ = try await right.receive(fragment, from: "peer") }
        }
        #expect(try await UtteranceRepository(other).fetch(meetingId: meeting.id).first?.text == edited)
        #expect(try await UtteranceRepository(upgraded).fetch(meetingId: meeting.id).first?.id == utterance.id)
    }

    @Test func UUIDAliasesResolveExistingMeetingSpeakerAndChildrenWithoutRekey() async throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await sync(a), right = try await sync(b)
        let original = Meeting(title: "original", startedAt: Date(), originDeviceId: "a")
        let speaker = Speaker(displayName: "Same name", anonymousName: "Fox", originDeviceId: "a")
        var copy = original; copy.id = original.id.lowercased()
        var copiedSpeaker = speaker; copiedSpeaker.id = speaker.id.lowercased()
        try await MeetingRepository(a).insert(original)
        try await SpeakerRepository(a).upsert(speaker)
        try await MeetingRepository(b).insert(copy)
        try await SpeakerRepository(b).upsert(copiedSpeaker)
        let utterance = Utterance(meetingId: original.id, startMs: 0, endMs: 10, text: "alias",
                                  speakerId: speaker.id, originDeviceId: "a")
        try await UtteranceRepository(a).append(utterance)
        try await SpeakerRepository(a).assignDisplayIndex(meetingId: original.id, speakerId: speaker.id, displayIndex: 0, deviceId: "a")
        try await exchange(left, right)
        let rows = try await MeetingRepository(b).fetchAll()
        #expect(rows.map(\.id) == [copy.id])
        let child = try #require(try await UtteranceRepository(b).fetch(meetingId: copy.id).first)
        #expect(child.meetingId == copy.id && child.speakerId == copiedSpeaker.id)
        #expect(try await SpeakerRepository(b).fetchAll().map(\.id) == [copiedSpeaker.id])
        #expect(try await right.transcriptRevision(meetingID: original.id) == left.transcriptRevision(meetingID: original.id))
        try await MeetingRepository(a).rename(id: original.id, title: "edited", deviceId: "a")
        try await exchange(left, right)
        #expect(try await MeetingRepository(b).fetch(id: copy.id)?.title == "edited")
    }

    @Test func incrementalProjectionDoesNotRewriteUnchangedTranscriptOrFTS() async throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await sync(a), right = try await sync(b)
        let meeting = Meeting(title: "large", startedAt: Date(), originDeviceId: "a")
        try await MeetingRepository(a).insert(meeting)
        for index in 0..<40 {
            try await UtteranceRepository(a).append(.init(meetingId: meeting.id, startMs: index, endMs: index + 1,
                text: "row \(index)", originDeviceId: "a"))
        }
        try await exchange(left, right)
        try await b.writer.write { db in
            try db.execute(sql: """
                CREATE TABLE writes(kind TEXT);
                CREATE TRIGGER count_text AFTER UPDATE ON utterance BEGIN INSERT INTO writes VALUES('utterance'); END;
                CREATE TRIGGER count_fts AFTER UPDATE OF text ON searchDocument BEGIN INSERT INTO writes VALUES('fts'); END;
                """)
        }
        try await MeetingRepository(a).setEmoji(id: meeting.id, emoji: "🦊", deviceId: "a")
        let operations = try await left.pending(peerID: "peer")
        for _ in 0..<5 { try await right.apply(operations, from: "peer") }
        #expect(try await b.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM writes") } == 0)
    }

    @Test func concurrentMembershipTagsAreAllObservedRemovedAndMergeRekeys() async throws {
        for seed in 0..<8 {
            let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
            let left = try await sync(a), right = try await sync(b)
            let meeting = Meeting(title: "members", startedAt: Date(), originDeviceId: "a")
            let keep = Speaker(anonymousName: "Fox", originDeviceId: "a")
            let absorb = Speaker(anonymousName: "Otter", originDeviceId: "a")
            try await MeetingRepository(a).insert(meeting)
            try await SpeakerRepository(a).upsert(keep)
            try await SpeakerRepository(a).upsert(absorb)
            try await exchange(left, right)
            for db in [a, b] {
                try await SpeakerRepository(db).assignDisplayIndex(meetingId: meeting.id, speakerId: absorb.id, displayIndex: 0, deviceId: "local")
            }
            try await exchange(left, right)
            try await exchange(right, left)
            let count = try await a.reader.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM automaticSyncAssociation WHERE meetingID=? AND speakerID=?", arguments: [meeting.id, absorb.id])
            }
            #expect(count == 2)
            try await SpeakerRepository(a).mergeSpeakers(keep: keep.id, absorb: absorb.id, deviceId: "a")
            let edits = try await left.pending(peerID: "peer", limit: 256)
            let ordered = seed % 2 == 0 ? edits : edits.reversed()
            for operation in ordered + ordered { try await right.apply([operation], from: "peer") }
            #expect(try await SpeakerRepository(b).speakers(inMeeting: meeting.id).map(\.speaker.id) == [keep.id])
            try await a.writer.write { try $0.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId=?", arguments: [meeting.id]) }
            try await exchange(left, right)
            for operation in edits { try await right.apply([operation], from: "peer") }
            #expect(try await SpeakerRepository(b).speakers(inMeeting: meeting.id).isEmpty)
        }
    }

    @Test func bilateralConsentFiltersIdentityOperationsBeforeLimitAndRejectsMisclassification() async throws {
        let db = try AppDatabase.inMemory()
        let repo = try await sync(db)
        for index in 0..<20 {
            try await SpeakerRepository(db).upsert(.init(anonymousName: "animal \(index)", originDeviceId: "a"))
        }
        let meeting = Meeting(title: "not starved", startedAt: Date(), originDeviceId: "a")
        try await MeetingRepository(db).insert(meeting)
        let pending = try await repo.pending(peerID: "peer", limit: 1, includeBiometrics: false)
        #expect(pending.count == 1 && pending[0].entity == .meeting && !pending[0].biometric)
        let receiverDB = try AppDatabase.inMemory()
        let receiver = try await sync(receiverDB, consent: .denied)
        let identity = try #require(try await repo.pending(peerID: "peer", limit: 1).first)
        #expect(identity.biometric)
        await #expect(throws: Wire.Failure.consentRequired) { try await receiver.apply([identity], from: "peer") }
        var forged = identity; forged.biometric = false
        await #expect(throws: Wire.Failure.invalid) { try await receiver.apply([forged], from: "peer") }
        try await receiver.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let encoded = try Wire.encode(identity)
        let boundary = encoded.count / 2
        let prefix = Wire.Fragment(operationID: identity.id, offset: 0, total: encoded.count, bytes: encoded.prefix(boundary))
        let suffix = Wire.Fragment(operationID: identity.id, offset: boundary, total: encoded.count, bytes: encoded.suffix(encoded.count - boundary))
        #expect(try await receiver.receive(prefix, from: "peer", includeBiometrics: true) == nil)
        await #expect(throws: Wire.Failure.consentRequired) {
            try await receiver.receive(suffix, from: "peer", includeBiometrics: false)
        }
        #expect(try await receiver.audit(entity: identity.entity, id: identity.entityID).isEmpty)
        #expect(try await receiver.receive(suffix, from: "peer", includeBiometrics: true) == identity.id)
        let hello = Wire.Message(kind: .hello, capability: Wire.capability)
        #expect(try Wire.decode(Wire.encode(hello)).voiceprintsAllowed == false)
        let ack = Wire.Message(kind: .ack, operationID: "x")
        var json = try #require(JSONSerialization.jsonObject(with: Wire.encode(ack)) as? [String: Any])
        json["voiceprintsAllowed"] = false
        #expect(throws: (any Error).self) {
            try Wire.decode(JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
    }

    @Test func voiceprintAdoptionMatchesExactNamespacesAndRevocationRemovesMatcherEntry() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await sync(a), right = try await sync(b)
        let speaker = Speaker(displayName: "Named", anonymousName: "Original Fox", originDeviceId: "a")
        try await SpeakerRepository(a).upsert(speaker)
        let embedding = SpeakerEmbedding(speakerId: speaker.id, floats: [1, 0], sampleCount: 7, originDeviceId: "a",
            modelIdentifier: "model", preprocessing: VoiceprintPreprocessing.campPlus)
        try await SpeakerRepository(a).addEmbedding(embedding)
        let resourceOp = try #require(try await left.pending(peerID: "peer", limit: 256).first { $0.entity == .resource })
        try await exchange(left, right)
        let bytes = try #require(try await left.resourceBytes(id: resourceOp.entityID, for: "peer"))
        let source = directory.appendingPathComponent("vector")
        try bytes.write(to: source)
        _ = try await right.installResource(id: resourceOp.entityID, from: source, directory: directory.appendingPathComponent("received"))
        #expect(try await right.pendingApplications(peerID: "peer") == [resourceOp.entityID])
        #expect(try await right.pendingApplications(peerID: "peer", includeBiometrics: false).isEmpty)
        #expect(try await right.reconcileVerifiedResources(from: "peer", includeBiometrics: false).isEmpty)
        #expect(try await right.reconcileVerifiedResources(from: "peer", includeBiometrics: true).first?.status == .applied)
        #expect(try await right.pendingApplications(peerID: "peer").isEmpty)
        #expect(try await SpeakerRepository(b).embeddings(forSpeaker: speaker.id).first?.sampleCount == 7)
        let matcher = VoiceprintMatcher(speakers: SpeakerRepository(b), modelIdentifier: "model")
        guard case .matched(let matched, _) = try await matcher.match(embedding: [1, 0], cleanDuration: 3) else {
            Issue.record("Compatible verified vector must participate"); return
        }
        #expect(matched == speaker.id)
        #expect(try await SpeakerRepository(b).fetch(id: speaker.id)?.anonymousName == "Original Fox")
        let other = VoiceprintMatcher(speakers: SpeakerRepository(b), modelIdentifier: "model", preprocessing: "different")
        #expect(try await other.match(embedding: [1, 0], cleanDuration: 3) == .noMatch(candidates: []))
        #expect(try await matcher.match(embedding: [1, 0, 0], cleanDuration: 3) == .noMatch(candidates: []))
        try await right.setVoiceprintConsent(peerID: "peer", state: .revoked)
        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 3) == .noMatch(candidates: []))
        let legacy = SpeakerEmbedding(speakerId: speaker.id, floats: [1, 0], originDeviceId: "local", modelIdentifier: "model")
        try await SpeakerRepository(b).addEmbedding(legacy)
        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 3) == .noMatch(candidates: []))
    }

    @Test(arguments: [false, true])
    func legacyVectorsBackfillAndTransferWithoutMatching(omitsCount: Bool) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let speaker = Speaker(displayName: "Legacy", anonymousName: "Original Fox", originDeviceId: "a")
        let embedding = SpeakerEmbedding(speakerId: speaker.id, floats: [1, 0], sampleCount: 7, originDeviceId: "a")
        try await a.writer.write { db in
            try speaker.insert(db)
            try embedding.insert(db)
        }
        let left = try await sync(a), right = try await sync(b)
        let operation = try #require(try await left.pending(peerID: "peer", limit: 256).first { $0.entity == .resource })
        var descriptor = try JSONDecoder().decode(Wire.Resource.self, from: Data(try #require(operation.value).utf8))
        #expect(descriptor.modelFingerprint == nil)
        #expect(descriptor.preprocessing == nil)
        #expect(descriptor.sampleCount == 7)
        let resourceID: String
        if omitsCount {
            descriptor.sampleCount = nil
            resourceID = try await left.registerResource(descriptor)
        } else {
            resourceID = operation.entityID
        }
        let before = try await left.pending(peerID: "peer", limit: 256)
        try await left.configure(peerID: "peer", enabled: true)
        #expect(try await left.pending(peerID: "peer", limit: 256) == before)
        try await exchange(left, right)
        let source = directory.appendingPathComponent("legacy-vector")
        let bytes = try #require(try await left.resourceBytes(id: operation.entityID, for: "peer"))
        #expect(bytes == embedding.vector)
        try bytes.write(to: source)
        _ = try await right.installResource(id: resourceID, from: source, directory: directory.appendingPathComponent("received"))
        try await right.adoptVoiceprintResource(id: resourceID)
        let imported = try #require(try await SpeakerRepository(b).embeddings(forSpeaker: speaker.id).first)
        #expect(imported.vector == embedding.vector)
        #expect(imported.sampleCount == (omitsCount ? 0 : 7))
        #expect(imported.modelIdentifier == nil)
        #expect(imported.preprocessing == nil)
        let matcher = VoiceprintMatcher(speakers: SpeakerRepository(b), modelIdentifier: "model", includeLegacyEmbeddings: true)
        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 3) == .noMatch(candidates: []))
        #expect(try await right.pending(peerID: "peer", limit: 256).isEmpty)
    }

    @Test func atomicResourceRecoveryAndActiveJournalCleanup() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.onDisk(directory: directory.appendingPathComponent("db"))
        let repo = try await sync(db)
        let data = Data(repeating: 42, count: 1_100)
        let hash = IncrementalSHA256.hex(SHA256.hash(data: data))
        let descriptor = Wire.Resource(kind: .audio, meetingID: "meeting", sha256: hash, byteCount: 1_100)
        let id = try await repo.registerResource(descriptor)
        let files = directory.appendingPathComponent("files")
        let transfer = AutomaticSyncResourceTransfer(db, directory: files)
        #expect(try await transfer.receive(.init(resourceID: id, offset: 0, total: 1_100, bytes: data.prefix(768)), from: "peer") == 768)
        try await db.writer.write { sql in
            try sql.execute(sql: "INSERT INTO automaticSyncFileGarbage SELECT localPath FROM automaticSyncResourceReceive")
        }
        try await repo.collectRevokedFiles()
        #expect(try await transfer.progress(resourceID: id, from: "peer") == 768)
        try Data([42]).write(to: files.appendingPathComponent(hash + ".m4a"))
        let reopened = try AppDatabase.onDisk(directory: directory.appendingPathComponent("db"))
        let recovered = AutomaticSyncResourceTransfer(reopened, directory: files)
        #expect(try await recovered.receive(.init(resourceID: id, offset: 768, total: 1_100, bytes: data.suffix(332)), from: "peer") == 1_100)
        #expect(try Data(contentsOf: files.appendingPathComponent(hash + ".m4a")) == data)
    }

    @Test func sharedHashAdoptionUsesIndependentAudioStoreFilesAndVerifiedProvenance() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try AppDatabase.inMemory(), b = try AppDatabase.onDisk(directory: directory.appendingPathComponent("db"))
        let left = try await sync(a), right = try await sync(b)
        let data = Data(repeating: 7, count: 32)
        let hash = IncrementalSHA256.hex(SHA256.hash(data: data))
        var ids: [String] = []
        var meetings: [Meeting] = []
        for index in 0..<2 {
            var meeting = Meeting(title: "audio \(index)", startedAt: Date(), state: .recorded, originDeviceId: "a")
            meeting.audioSHA256 = hash; meeting.audioByteCount = data.count
            try await MeetingRepository(a).insert(meeting)
            ids.append(try AutomaticSyncRepository.resourceID(.init(kind: .audio, meetingID: meeting.id, sha256: hash, byteCount: 32)))
            meetings.append(meeting)
        }
        try await exchange(left, right)
        #expect(try await right.verifiedAudioImports().isEmpty)
        let store = AudioFileStore(directory: directory.appendingPathComponent("audio"))
        let source = directory.appendingPathComponent("source")
        try data.write(to: source)
        for id in ids {
            _ = try await right.installResource(id: id, from: source, directory: store.directory)
            #expect(try await right.pendingApplications(peerID: "peer") == [id])
            #expect(try await right.reconcileVerifiedResources(from: "peer", includeBiometrics: false).first?.status == .applied)
            #expect(try await right.pendingApplications(peerID: "peer").isEmpty)
        }
        let imported = try await right.verifiedAudioImports()
        #expect(imported.count == 2 && imported.allSatisfy { $0.peerID == "peer" && !$0.operationID.isEmpty })
        for item in imported {
            #expect(try await left.audit(entity: .resource, id: item.resourceID).first?.id == item.operationID)
        }
        let restarted = AutomaticSyncRepository(try AppDatabase.onDisk(directory: directory.appendingPathComponent("db")))
        #expect(try await restarted.verifiedAudioImports() == imported)
        #expect(try await restarted.pendingApplications(peerID: "peer").isEmpty)
        try await restarted.configure(peerID: "peer", enabled: false)
        #expect(try await right.verifiedAudioImports().isEmpty)
        try await restarted.configure(peerID: "unrelated", enabled: true)
        #expect(try await right.verifiedAudioImports().isEmpty)
        try await restarted.configure(peerID: "peer", enabled: true)
        #expect(try await right.verifiedAudioImports() == imported)
        let first = try #require(try await MeetingRepository(b).fetch(id: meetings[0].id)?.audioFileName)
        let second = try #require(try await MeetingRepository(b).fetch(id: meetings[1].id)?.audioFileName)
        #expect(first != second)
        try await MeetingRepository(b).delete(id: meetings[0].id)
        try store.remove(fileName: first)
        #expect(store.exists(fileName: second))
        #expect(try Data(contentsOf: store.url(forFileName: second)) == data)
        #expect(try await right.verifiedAudioImports().count == 1)
    }

    @Test func snapshotFencedLegacyPublicationRejectsNewerAssignments() async throws {
        let database = try AppDatabase.inMemory()
        let repository = try await sync(database)
        let meeting = Meeting(title: "snapshot", startedAt: Date(), durationMs: 1_000,
                              audioSHA256: String(repeating: "a", count: 64), state: .recorded, originDeviceId: "source")
        try await MeetingRepository(database).insert(meeting)
        let source = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1_000, text: "user text", originDeviceId: "source")
        try await UtteranceRepository(database).append(source)
        let snapshot = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        let revision = try await repository.transcriptRevision(meetingID: meeting.id)
        let speaker = Speaker(anonymousName: "assigned later", originDeviceId: "source")
        try await SpeakerRepository(database).upsert(speaker)
        try await database.writer.write {
            try $0.execute(sql: "UPDATE utterance SET speakerId=? WHERE id=?", arguments: [speaker.id, source.id])
        }
        #expect(try await repository.transcriptRevision(meetingID: meeting.id) == revision)
        let before = try await repository.pending(peerID: "peer", limit: 256)
        await #expect(throws: Wire.Failure.staleRevision) {
            try await repository.publishTranscript(meetingID: meeting.id, expectedAudioSHA256: meeting.audioSHA256!,
                expectedRevision: revision, utterances: [.init(meetingId: meeting.id, startMs: 0, endMs: 900, text: "new ASR", originDeviceId: "mac")],
                publicationID: "snapshot", modelFingerprint: "model", preprocessing: "16k", expectedUtterances: snapshot)
        }
        #expect(try await repository.pending(peerID: "peer", limit: 256) == before)
        #expect(try await UtteranceRepository(database).fetch(meetingId: meeting.id).first?.text == source.text)
        #expect(try await UtteranceRepository(database).fetch(meetingId: meeting.id).first?.speakerId == speaker.id)
    }

    @Test func remoteDeletionCleansOriginalAudioAfterRestartButRetainsOtherOwners() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try AppDatabase.inMemory(), b = try AppDatabase.onDisk(directory: directory.appendingPathComponent("db"))
        let left = try await sync(a), right = try await sync(b)
        let audio = directory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3, 4])
        for name in ["original.m4a", "shared.m4a"] { try bytes.write(to: audio.appendingPathComponent(name)) }
        let outside = directory.appendingPathComponent("outside.m4a")
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: audio.appendingPathComponent("link.m4a"), withDestinationURL: outside)
        let speaker = Speaker(anonymousName: "global", originDeviceId: "local")
        try await SpeakerRepository(b).upsert(speaker)
        let embedding = SpeakerEmbedding(speakerId: speaker.id, floats: [1, 0], originDeviceId: "local",
                                        modelIdentifier: "model", preprocessing: VoiceprintPreprocessing.campPlus)
        try await SpeakerRepository(b).addEmbedding(embedding)
        let vectorID = try #require(try await right.pending(peerID: "peer", limit: 256).first { $0.entity == .resource }?.entityID)
        let vectorSource = directory.appendingPathComponent("vector")
        try embedding.vector.write(to: vectorSource)
        let vectorURL = try await right.installResource(id: vectorID, from: vectorSource, directory: audio)
        let names = ["original.m4a", "shared.m4a", "shared.m4a", "../outside.m4a", "link.m4a", vectorURL.lastPathComponent]
        var meetings: [Meeting] = []
        for name in names {
            let meeting = Meeting(title: name, startedAt: Date(), originDeviceId: "source")
            try await MeetingRepository(a).insert(meeting)
            meetings.append(meeting)
        }
        try await exchange(left, right)
        for (meeting, name) in zip(meetings, names) {
            try await b.writer.write {
                try $0.execute(sql: "UPDATE meeting SET audioFileName=? WHERE id=?", arguments: [name, meeting.id])
            }
        }
        try await right.cleanupDeletedMeetingAudio(audioDirectory: audio)
        #expect(try Data(contentsOf: audio.appendingPathComponent("original.m4a")) == bytes)
        for index in [0, 1, 3, 4, 5] { try await MeetingRepository(a).delete(id: meetings[index].id) }
        try await exchange(left, right)
        #expect(FileManager.default.fileExists(atPath: audio.appendingPathComponent("original.m4a").path))
        let restarted = AutomaticSyncRepository(try AppDatabase.onDisk(directory: directory.appendingPathComponent("db")))
        try await restarted.cleanupDeletedMeetingAudio(audioDirectory: audio)
        #expect(!FileManager.default.fileExists(atPath: audio.appendingPathComponent("original.m4a").path))
        #expect(try Data(contentsOf: audio.appendingPathComponent("shared.m4a")) == bytes)
        #expect(try Data(contentsOf: outside) == bytes)
        #expect(try Data(contentsOf: vectorURL) == embedding.vector)
        #expect(try await SpeakerRepository(b).fetch(id: speaker.id) != nil)
        try await MeetingRepository(a).delete(id: meetings[2].id)
        try await exchange(left, restarted)
        try await restarted.cleanupDeletedMeetingAudio(audioDirectory: audio)
        #expect(!FileManager.default.fileExists(atPath: audio.appendingPathComponent("shared.m4a").path))
        #expect(try Data(contentsOf: vectorURL) == embedding.vector)
    }

    @Test(arguments: [false, true])
    func meetingDeletionCollectsArtifactsAfterRestartWithoutDeletingSharedOrGlobalResources(remote: Bool) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDB = try AppDatabase.inMemory()
        let dbDirectory = directory.appendingPathComponent("db")
        let targetDB = try AppDatabase.onDisk(directory: dbDirectory)
        let source = try await sync(sourceDB), target = try await sync(targetDB)
        let audioDirectory = directory.appendingPathComponent("audio")
        let meetings = (0..<2).map { Meeting(title: "Owner \($0)", startedAt: Date(), originDeviceId: "source") }
        for meeting in meetings { try await MeetingRepository(sourceDB).insert(meeting) }
        let speaker = try await SpeakerRepository(sourceDB).createAnonymousSpeaker(deviceId: "source")
        let embedding = SpeakerEmbedding(speakerId: speaker.id, floats: [1, 0], sampleCount: 7, originDeviceId: "source")
        try await SpeakerRepository(sourceDB).addEmbedding(embedding)
        let vectorID = try #require(try await source.pending(peerID: "peer", limit: 256).first { $0.entity == .resource }?.entityID)
        let audioBytes = Data([1, 2, 3, 4]), analysisBytes = Data("analysis artifact".utf8)
        var ids: [[String]] = []
        for meeting in meetings {
            var owned: [String] = []
            for (kind, bytes) in [(Wire.Resource.Kind.audio, audioBytes), (.analysis, analysisBytes), (.transcript, Data("transcript".utf8))] {
                let id = try await source.registerResource(.init(kind: kind, meetingID: meeting.id,
                    sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count),
                    modelFingerprint: kind == .audio ? nil : "fixture-model",
                    preprocessing: kind == .audio ? nil : "fixture-preprocessing",
                    inputRevision: kind == .audio ? nil : "fixture-revision"))
                try await sourceDB.writer.write {
                    try $0.execute(sql: "INSERT INTO automaticSyncResourcePayload VALUES(?,?)", arguments: [id, bytes])
                }
                owned.append(id)
            }
            ids.append(owned)
        }
        try await exchange(source, target)
        var paths: [[URL]] = []
        for owned in ids {
            var files: [URL] = []
            for id in owned {
                let bytes = try #require(try await source.resourceBytes(id: id, for: "peer"))
                let input = directory.appendingPathComponent("input")
                try bytes.write(to: input)
                files.append(try await target.installResource(id: id, from: input, directory: audioDirectory))
                try await targetDB.writer.write {
                    try $0.execute(sql: "INSERT INTO automaticSyncResourcePayload VALUES(?,?)", arguments: [id, bytes])
                }
            }
            paths.append(files)
        }
        let vectorInput = directory.appendingPathComponent("vector-input")
        try embedding.vector.write(to: vectorInput)
        let vectorPath = try await target.installResource(id: vectorID, from: vectorInput, directory: audioDirectory)
        try await target.adoptVoiceprintResource(id: vectorID)
        try await target.adoptAudioResource(id: ids[0][0])
        let adoptedName = try #require(try await MeetingRepository(targetDB).fetch(id: meetings[0].id)?.audioFileName)
        let adoptedPath = audioDirectory.appendingPathComponent(adoptedName)
        #expect(FileManager.default.fileExists(atPath: paths[0][0].path))
        if remote {
            try await MeetingRepository(sourceDB).delete(id: meetings[0].id)
            try await exchange(source, target)
            for id in ids[0] {
                #expect(try await sourceDB.reader.read { try Data.fetchOne($0, sql: "SELECT bytes FROM automaticSyncResourcePayload WHERE resourceID=?", arguments: [id]) } == nil)
            }
        } else {
            try await MeetingRepository(targetDB).delete(id: meetings[0].id)
        }
        for id in ids[0] {
            #expect(try await targetDB.reader.read { try Data.fetchOne($0, sql: "SELECT bytes FROM automaticSyncResourcePayload WHERE resourceID=?", arguments: [id]) } == nil)
        }
        let reopened = try AppDatabase.onDisk(directory: dbDirectory)
        let restarted = AutomaticSyncRepository(reopened)
        try await restarted.cleanupDeletedMeetingAudio(audioDirectory: audioDirectory)
        try await restarted.collectRevokedFiles()
        #expect(!FileManager.default.fileExists(atPath: adoptedPath.path))
        for path in paths[1] { #expect(FileManager.default.fileExists(atPath: path.path)) }
        #expect(try Data(contentsOf: vectorPath) == embedding.vector)
        try await MeetingRepository(reopened).delete(id: meetings[1].id)
        try await restarted.cleanupDeletedMeetingAudio(audioDirectory: audioDirectory)
        try await restarted.collectRevokedFiles()
        for path in paths[0] + paths[1] { #expect(!FileManager.default.fileExists(atPath: path.path)) }
        #expect(try Data(contentsOf: vectorPath) == embedding.vector)
        #expect(try await SpeakerRepository(reopened).embeddings(forSpeaker: speaker.id).first?.vector == embedding.vector)
        #expect(try await restarted.resource(id: vectorID) != nil)
    }

    @Test func v14CollectsResourcesOfPreviouslyDeletedMeetings() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v13_deleted_meeting_audio")
        let meeting = Meeting(title: "Old deletion", startedAt: Date(), originDeviceId: "source")
        let bytes = Data([1, 2, 3])
        let path = directory.appendingPathComponent("orphaned-audio")
        try bytes.write(to: path)
        let id = try await queue.write { db in
            try meeting.insert(db)
            let id = try AutomaticSyncRepository.registerResource(db, descriptor: .init(kind: .audio, meetingID: meeting.id,
                sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count)))
            try db.execute(sql: "INSERT INTO automaticSyncResourceFile VALUES(?,?,1,?)", arguments: [id, path.lastPathComponent, path.path])
            try db.execute(sql: "INSERT INTO automaticSyncResourcePayload VALUES(?,?)", arguments: [id, bytes])
            try meeting.delete(db)
            return id
        }
        let upgraded = try AppDatabase(queue)
        #expect(try await upgraded.reader.read { try Data.fetchOne($0, sql: "SELECT bytes FROM automaticSyncResourcePayload WHERE resourceID=?", arguments: [id]) } == nil)
        try await AutomaticSyncRepository(upgraded).collectRevokedFiles()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func processingIdentityFenceAllowsTitleOnlyChanges() async throws {
        let database = try AppDatabase.inMemory()
        let repository = try await sync(database)
        let meeting = Meeting(title: "before", startedAt: Date(), durationMs: 1_000,
                              audioSHA256: String(repeating: "a", count: 64), state: .recorded, originDeviceId: "source")
        try await MeetingRepository(database).insert(meeting)
        try await UtteranceRepository(database).append(.init(meetingId: meeting.id, startMs: 0, endMs: 1_000,
                                                            text: "source", originDeviceId: "source"))
        let token = try await repository.captureProcessingInput(meetingID: meeting.id)
        try await database.writer.write {
            try $0.execute(sql: "UPDATE meeting SET title=? WHERE id=?", arguments: ["User title", meeting.id])
        }
        #expect(try await repository.captureProcessingInput(meetingID: meeting.id) == token)
        let replacement = Utterance(meetingId: meeting.id, startMs: 0, endMs: 900,
                                    text: "new output", originDeviceId: "mac")
        let output = try await repository.publishTranscript(input: token, utterances: [replacement],
            publicationID: "title-only", modelFingerprint: "model", preprocessing: "16k")
        #expect(try await repository.transcriptRevision(meetingID: meeting.id) == output)
        #expect(try await MeetingRepository(database).fetch(id: meeting.id)?.title == "User title")
    }

    @Test func verifiedAnalysisRestartRetainsOutOfOrderCandidateUntilDependenciesArrive() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try AppDatabase.inMemory()
        let dbDirectory = directory.appendingPathComponent("db")
        let b = try AppDatabase.onDisk(directory: dbDirectory)
        let left = try await sync(a), right = try await sync(b)
        let meeting = Meeting(title: "analysis restart", startedAt: Date(), originDeviceId: "a")
        try await MeetingRepository(a).insert(meeting)
        try await UtteranceRepository(a).append(.init(meetingId: meeting.id, startMs: 0, endMs: 100,
                                                      text: "delayed source", originDeviceId: "a"))
        let input = try await left.transcriptRevision(meetingID: meeting.id)
        let draft = AnalysisResultDraft(meetingId: meeting.id, kind: .qa, payloadJSON: "{\"answer\":\"verified\"}",
                                        producedByDeviceId: "mac")
        try await AnalysisResultRepository(a).record(draft, inputRevision: input, modelFingerprint: "model", preprocessing: "v1")
        let operations = try await left.pending(peerID: "peer", limit: 256)
        let resource = try #require(operations.first { $0.entity == .resource })
        try await right.apply(operations.filter { $0.entity != .utterance }, from: "peer")
        let source = directory.appendingPathComponent("analysis")
        try #require(try await left.resourceBytes(id: resource.entityID, for: "peer")).write(to: source)
        _ = try await right.installResource(id: resource.entityID, from: source, directory: directory.appendingPathComponent("files"))
        let restarted = AutomaticSyncRepository(try AppDatabase.onDisk(directory: dbDirectory))
        #expect(try await restarted.resourcesNeedingDownload(from: "peer").isEmpty)
        #expect(try await restarted.pendingApplications(peerID: "peer") == [resource.entityID])
        #expect(try await restarted.reconcileVerifiedResources(from: "peer", includeBiometrics: false).first?.status == .stale)
        #expect(try await restarted.pendingApplications(peerID: "peer") == [resource.entityID])
        try await restarted.apply(operations.filter { $0.entity == .utterance }, from: "peer")
        #expect(try await restarted.reconcileVerifiedResources(from: "peer", includeBiometrics: false).first?.status == .applied)
        let completed = AutomaticSyncRepository(try AppDatabase.onDisk(directory: dbDirectory))
        #expect(try await completed.pendingApplications(peerID: "peer").isEmpty)
        #expect(try await completed.reconcileVerifiedResources(from: "peer", includeBiometrics: false).isEmpty)
        #expect(try await completed.publishedResource(meetingID: meeting.id, kind: .analysis) == resource.entityID)
        try await completed.publishResource(id: resource.entityID)
        #expect(try await completed.pending(peerID: "peer").isEmpty)
    }

    @Test func typedTranscriptPublicationIsAtomicInputFencedAndReturnsViaResource() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await sync(a, consent: .denied), right = try await sync(b, consent: .denied)
        var meeting = Meeting(title: "reprocess", startedAt: Date(), durationMs: 1_000, state: .recorded, originDeviceId: "a")
        meeting.audioSHA256 = String(repeating: "a", count: 64)
        let audioHash = meeting.audioSHA256!
        let meetingID = meeting.id
        try await MeetingRepository(a).insert(meeting)
        let speaker = Speaker(displayName: "Local name", anonymousName: "Original animal", originDeviceId: "a")
        try await SpeakerRepository(a).upsert(speaker)
        let original = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1_000, text: "old",
                                  speakerId: speaker.id, originDeviceId: "a")
        try await UtteranceRepository(a).append(original)
        try await exchange(left, right)
        // The real audio adoption sets this local, non-replicated seal.
        try await b.writer.write { try $0.execute(sql: "UPDATE meeting SET audioSHA256=? WHERE id=?", arguments: [audioHash, meetingID]) }
        let revision = try await left.transcriptRevision(meetingID: meeting.id)
        let expectedSnapshot = try await UtteranceRepository(a).fetch(meetingId: meeting.id)
        let replacement = Utterance(meetingId: meeting.id, startMs: 10, endMs: 900, text: "timed\0result", originDeviceId: "mac")
        let output = try await left.publishTranscript(meetingID: meeting.id, expectedAudioSHA256: audioHash,
            expectedRevision: revision, utterances: [replacement], publicationID: "job",
            modelFingerprint: "model", preprocessing: "asr16k", expectedUtterances: expectedSnapshot)
        #expect(try await left.transcriptMappings(publicationID: "job").first?.sourceStartMs == 0)
        #expect(try await left.transcriptMappings(publicationID: "job").first?.targetID == replacement.id)
        #expect(try await left.publishTranscript(meetingID: meetingID, expectedAudioSHA256: audioHash,
            expectedRevision: revision, utterances: [replacement], publicationID: "job",
            modelFingerprint: "model", preprocessing: "asr16k", expectedUtterances: expectedSnapshot) == output)
        await #expect(throws: Wire.Failure.equivocation) {
            try await left.publishTranscript(meetingID: meetingID, expectedAudioSHA256: audioHash,
                expectedRevision: revision, utterances: [replacement], publicationID: "job",
                modelFingerprint: "different-model", preprocessing: "asr16k")
        }
        let operations = try await left.pending(peerID: "peer", limit: 256)
        #expect(operations.count == 1 && operations[0].entity == .resource)
        try await right.apply(operations, from: "peer")
        #expect(try await right.transcriptRevision(meetingID: meetingID) == revision)
        #expect(try await UtteranceRepository(b).fetch(meetingId: meetingID).first?.id == original.id)
        let id = operations[0].entityID
        let source = directory.appendingPathComponent("transcript")
        try #require(try await left.resourceBytes(id: id, for: "peer")).write(to: source)
        _ = try await right.installResource(id: id, from: source, directory: directory.appendingPathComponent("received"))
        #expect(try await right.pendingApplications(peerID: "peer") == [id])
        #expect(try await right.transcriptRevision(meetingID: meetingID) == revision)
        #expect(try await right.reconcileVerifiedResources(from: "peer", includeBiometrics: false).first?.status == .applied)
        #expect(try await right.pendingApplications(peerID: "peer").isEmpty)
        try await right.publishResource(id: id)
        #expect(try await right.transcriptRevision(meetingID: meeting.id) == output)
        let rows = try await UtteranceRepository(b).fetch(meetingId: meeting.id)
        #expect(rows.first?.text == replacement.text && rows.first?.startMs == 10 && rows.count == 1)
        #expect(rows.first?.speakerId == nil)
        #expect(try await right.pending(peerID: "peer").isEmpty)
        try await right.configure(peerID: "replacement-phone", enabled: true)
        let relayed = try await right.pending(peerID: "replacement-phone", limit: 256)
        #expect(relayed.contains { $0.entity == .resource && $0.entityID == id })
        let internalIDs = try await b.reader.read {
            try String.fetchAll($0, sql: "SELECT id FROM automaticSyncOperation WHERE sourcePeer GLOB 'publication:*'")
        }
        #expect(!internalIDs.isEmpty)
        #expect(Set(relayed.map(\.id)).isDisjoint(with: internalIDs))
        #expect(try await right.status(peerID: "replacement-phone").pendingCount == relayed.count)
        await #expect(throws: Wire.Failure.invalid) {
            try await right.acknowledge(peerID: "replacement-phone", operationIDs: internalIDs)
        }
        try await left.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await right.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await exchange(left, right)
        #expect(try await UtteranceRepository(b).fetch(meetingId: meetingID).first?.speakerId == speaker.id)
        let recipientEdit = "recipient edit after publication"
        try await b.writer.write {
            try $0.execute(sql: "UPDATE utterance SET text=? WHERE id=?", arguments: [recipientEdit, replacement.id])
        }
        let recipientRevision = try await right.transcriptRevision(meetingID: meetingID)
        let recipientPending = try await right.pending(peerID: "peer")
        try await right.apply(operations, from: "peer")
        try await right.publishResource(id: id)
        #expect(try await right.transcriptRevision(meetingID: meetingID) == recipientRevision)
        #expect(try await UtteranceRepository(b).fetch(meetingId: meetingID).first?.text == recipientEdit)
        #expect(try await right.pending(peerID: "peer") == recipientPending)
        let newer = "newer user edit"
        try await a.writer.write { try $0.execute(sql: "UPDATE utterance SET text=? WHERE id=?", arguments: [newer, replacement.id]) }
        await #expect(throws: Wire.Failure.staleRevision) {
            try await left.publishTranscript(meetingID: meeting.id, expectedAudioSHA256: audioHash,
                expectedRevision: output, utterances: [.init(meetingId: meeting.id, startMs: 0, endMs: 1, text: "stale", originDeviceId: "mac")],
                publicationID: "stale-job", modelFingerprint: "model", preprocessing: "asr16k")
        }
        #expect(try await UtteranceRepository(a).fetch(meetingId: meeting.id).first?.text == newer)
        let c = try AppDatabase.inMemory()
        let third = try await sync(c, consent: .denied)
        try await MeetingRepository(c).insert(meeting)
        var unassigned = original
        unassigned.speakerId = nil
        unassigned.text = "remote user edit"
        try await UtteranceRepository(c).append(unassigned)
        try await third.apply(operations, from: "peer")
        _ = try await third.installResource(id: id, from: source, directory: directory.appendingPathComponent("third"))
        await #expect(throws: Wire.Failure.staleRevision) { try await third.publishResource(id: id) }
        #expect(try await third.pendingApplications(peerID: "peer") == [id])
        #expect(try await UtteranceRepository(c).fetch(meetingId: meetingID).first?.text == "remote user edit")
        #expect(try await third.resource(id: id) != nil)
        try await MeetingRepository(c).delete(id: meetingID)
        let deletedRevision = try await third.transcriptRevision(meetingID: meetingID)
        await #expect(throws: Wire.Failure.staleRevision) {
            try await third.publishTranscript(meetingID: meetingID, expectedAudioSHA256: audioHash,
                expectedRevision: deletedRevision, utterances: [replacement], publicationID: "deleted-meeting",
                modelFingerprint: "model", preprocessing: "asr16k")
        }
        #expect(try await UtteranceRepository(c).fetch(meetingId: meetingID).isEmpty)
    }
}
