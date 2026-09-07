import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncPublicationReviewTests {
    typealias Wire = AutomaticSyncWire

    private final class FixtureFiles: @unchecked Sendable {
        let directory: URL
        let audio = Data("bounded synthetic publication audio bytes".utf8)
        init() throws {
            directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".publication-audio-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try audio.write(to: directory.appendingPathComponent("source.m4a"))
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Fixture {
        let files: FixtureFiles
        let db: AppDatabase
        let sync: AutomaticSyncRepository
        let meeting: Meeting
        let original: Utterance
        let operations: [Wire.Operation]
        let revision: String
    }

    private struct Artifact {
        let operation: Wire.Operation
        let operations: [Wire.Operation]
        let bytes: Data
        let output: Utterance
        let revision: String
    }

    private func folder() throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".publication-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture() async throws -> Fixture {
        let files = try FixtureFiles()
        let db = try AppDatabase.inMemory()
        let sync = AutomaticSyncRepository(db)
        try await sync.configure(peerID: "peer", enabled: true, voiceprints: .allowed)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        var meeting = Meeting(id: "transcript-qa", title: "review", startedAt: instant, durationMs: 1_000,
                              state: .recorded, createdAt: instant, updatedAt: instant, originDeviceId: "fixture")
        meeting.audioFileName = "source.m4a"
        meeting.audioSHA256 = IncrementalSHA256.hex(SHA256.hash(data: files.audio))
        meeting.audioByteCount = files.audio.count
        try await MeetingRepository(db).insert(meeting)
        let speaker = Speaker(anonymousName: "Fox", originDeviceId: "source")
        try await SpeakerRepository(db).upsert(speaker)
        let original = Utterance(id: "input-row", meetingId: meeting.id, startMs: 0, endMs: 1_000, text: "input",
                                 speakerId: speaker.id, createdAt: instant, updatedAt: instant, originDeviceId: "synthetic")
        try await UtteranceRepository(db).append(original)
        let operations = try await sync.pending(peerID: "peer", limit: 256)
        try await sync.acknowledge(peerID: "peer", operationIDs: operations.map(\.id))
        return Fixture(files: files, db: db, sync: sync, meeting: meeting, original: original, operations: operations,
                       revision: try await sync.transcriptRevision(meetingID: meeting.id))
    }

    private func replica(_ fixture: Fixture) async throws -> (AppDatabase, AutomaticSyncRepository) {
        let db = try AppDatabase.inMemory()
        let sync = AutomaticSyncRepository(db)
        try await sync.configure(peerID: "peer", enabled: true, voiceprints: .allowed)
        try await sync.apply(fixture.operations, from: "peer")
        let descriptor = try #require(fixture.operations.first { $0.entity == .resource })
        let transfer = AutomaticSyncResourceTransfer(db,
            directory: fixture.files.directory.appendingPathComponent(UUID().uuidString))
        _ = try await transfer.receive(.init(resourceID: descriptor.entityID, offset: 0,
            total: Int64(fixture.files.audio.count), bytes: fixture.files.audio), from: "peer")
        try await sync.adoptAudioResource(id: descriptor.entityID)
        return (db, sync)
    }

    private func artifact(_ fixture: Fixture, label: String, from sync: AutomaticSyncRepository? = nil,
                          input: String? = nil) async throws -> Artifact {
        let sender: AutomaticSyncRepository
        if let sync { sender = sync } else { sender = try await replica(fixture).1 }
        let output = Utterance(meetingId: fixture.meeting.id, startMs: 0, endMs: 1_000,
                               text: label, confidence: 0.12345678901234567, originDeviceId: "worker")
        let revision = try await sender.publishTranscript(meetingID: fixture.meeting.id,
            expectedAudioSHA256: fixture.meeting.audioSHA256!, expectedRevision: input ?? fixture.revision,
            utterances: [output], publicationID: label, modelFingerprint: "model", preprocessing: "asr16k")
        let operations = try await sender.pending(peerID: "peer", limit: 256)
        let operation = try #require(operations.first { $0.entity == .resource })
        return Artifact(operation: operation, operations: operations,
                        bytes: try #require(try await sender.resourceBytes(id: operation.entityID, for: "peer")),
                        output: output, revision: revision)
    }

    private func install(_ artifact: Artifact, on sync: AutomaticSyncRepository, directory: URL) async throws {
        try await sync.apply(artifact.operations, from: "peer")
        let source = directory.appendingPathComponent("source-\(artifact.operation.entityID)")
        try artifact.bytes.write(to: source)
        _ = try await sync.installResource(id: artifact.operation.entityID, from: source,
                                          directory: directory.appendingPathComponent(UUID().uuidString))
    }

    @Test(arguments: [false, true])
    func returnedTranscriptMergesLaterIdentityAssignment(clearIdentity: Bool) async throws {
        let fixture = try await fixture()
        let (macDatabase, mac) = try await replica(fixture)
        let returned = try await artifact(fixture, label: "returned-from-mac", from: mac)
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacementSpeaker = try await SpeakerRepository(fixture.db).createAnonymousSpeaker(deviceId: "phone")
        try await UtteranceRepository(fixture.db).assignSpeaker(
            utteranceId: fixture.original.id, speakerId: clearIdentity ? nil : replacementSpeaker.id, deviceId: "phone")
        #expect(try await fixture.sync.transcriptRevision(meetingID: fixture.meeting.id) != fixture.revision)
        try await install(returned, on: fixture.sync, directory: directory)
        try await fixture.sync.publishResource(id: returned.operation.entityID)
        let rows = try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id)
        #expect(rows.map(\.text) == ["returned-from-mac"])
        #expect(rows.map(\.speakerId) == [clearIdentity ? nil : replacementSpeaker.id])
        try await fixture.sync.publishResource(id: returned.operation.entityID)
        #expect(try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id) == rows)
        let corrections = try await fixture.sync.pending(peerID: "peer", limit: 256)
        try await mac.apply(corrections, from: "peer")
        try await mac.apply(corrections, from: "peer")
        let converged = try await UtteranceRepository(macDatabase).fetch(meetingId: fixture.meeting.id)
        #expect(converged.map(\.id) == rows.map(\.id))
        #expect(converged.map(\.speakerId) == rows.map(\.speakerId))
        #expect(!((try await mac.pending(peerID: "peer", limit: 256)).contains { $0.id.hasPrefix("mapped-") }))
    }

    @Test func returnedTranscriptStillRejectsContentEditsAlongsideIdentityRefinement() async throws {
        let fixture = try await fixture()
        let returned = try await artifact(fixture, label: "obsolete-mac-output")
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await UtteranceRepository(fixture.db).assignSpeaker(
            utteranceId: fixture.original.id, speakerId: nil, deviceId: "phone")
        try await fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE utterance SET text='Keep my correction', revision=revision+1 WHERE id=?",
                           arguments: [fixture.original.id])
        }
        let before = try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id)
        try await install(returned, on: fixture.sync, directory: directory)
        await #expect(throws: Wire.Failure.staleRevision) {
            try await fixture.sync.publishResource(id: returned.operation.entityID)
        }
        #expect(try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id) == before)
    }

    @Test(arguments: ["identity", "name", "text", "duration", "locale"])
    func publisherMergesIdentityMetadataButKeepsActualModelInputFences(change: String) async throws {
        let fixture = try await fixture()
        let input = try await fixture.sync.captureProcessingInput(meetingID: fixture.meeting.id)
        let expected = try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id)
        switch change {
        case "identity":
            try await UtteranceRepository(fixture.db).assignSpeaker(
                utteranceId: fixture.original.id, speakerId: nil, deviceId: "phone")
        case "name":
            try await SpeakerRepository(fixture.db).rename(
                id: try #require(fixture.original.speakerId), displayName: "Keep this name", deviceId: "phone")
        case "text":
            try await fixture.db.writer.write {
                try $0.execute(sql: "UPDATE utterance SET text='Keep this edit', revision=revision+1 WHERE id=?",
                               arguments: [fixture.original.id])
            }
        case "duration":
            try await fixture.db.writer.write {
                try $0.execute(sql: "UPDATE meeting SET durationMs=1500 WHERE id=?", arguments: [fixture.meeting.id])
            }
        default:
            try await fixture.db.writer.write {
                try $0.execute(sql: "UPDATE meeting SET localeIdentifier='zh-CN' WHERE id=?", arguments: [fixture.meeting.id])
            }
        }
        let output = Utterance(meetingId: fixture.meeting.id, startMs: 0, endMs: 1000, text: "Processed", originDeviceId: "mac")
        if change == "identity" || change == "name" {
            _ = try await fixture.sync.publishTranscript(input: input, utterances: [output], publicationID: "concurrent-\(change)",
                modelFingerprint: "model", preprocessing: "asr16k", expectedUtterances: expected)
            let rows = try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id)
            #expect(rows.map(\.text) == ["Processed"])
            if change == "identity" { #expect(rows.first?.speakerId == nil) }
            else {
                #expect(try await SpeakerRepository(fixture.db).fetch(id: try #require(fixture.original.speakerId))?.displayName == "Keep this name")
            }
        } else {
            let before = try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id)
            await #expect(throws: Wire.Failure.staleRevision) {
                try await fixture.sync.publishTranscript(input: input, utterances: [output], publicationID: "concurrent-\(change)",
                    modelFingerprint: "model", preprocessing: "asr16k", expectedUtterances: expected)
            }
            #expect(try await UtteranceRepository(fixture.db).fetch(meetingId: fixture.meeting.id) == before)
        }
    }

    @Test func metadataOnlyMacQAFixtureCannotEstablishAnAudioInput() async throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = AutomaticSyncRepository(a), right = AutomaticSyncRepository(b)
        try await left.configure(peerID: "peer", enabled: true)
        try await right.configure(peerID: "peer", enabled: true)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        try await MeetingRepository(a).insert(Meeting(id: "transcript-qa", title: "Original title",
            startedAt: instant, durationMs: 1_000, audioSHA256: String(repeating: "a", count: 64),
            state: .recorded, createdAt: instant, updatedAt: instant, originDeviceId: "fixture"))
        try await UtteranceRepository(a).append(Utterance(id: "input-row", meetingId: "transcript-qa",
            startMs: 0, endMs: 1_000, text: "Original transcript",
            createdAt: instant, updatedAt: instant, originDeviceId: "synthetic"))
        let initial = try await left.pending(peerID: "peer", limit: 512)
        #expect(!initial.contains { $0.entity == .resource })
        for operation in initial {
            for fragment in try Wire.fragments(for: operation) { _ = try await right.receive(fragment, from: "peer") }
        }
        #expect(try await left.transcriptRevision(meetingID: "transcript-qa")
            == right.transcriptRevision(meetingID: "transcript-qa"))
        #expect(try await MeetingRepository(b).fetch(id: "transcript-qa")?.audioSHA256 == nil)
        await #expect(throws: Wire.Failure.staleRevision) { try await right.captureProcessingInput(meetingID: "transcript-qa") }
        #expect(try await right.verifiedAudioImports().isEmpty)
    }

    @Test func receivingRelayedOperationRetiresOnlyThatPeersKnownOperation() async throws {
        let fixture = try await fixture()
        let (_, sync) = try await replica(fixture)
        try await sync.configure(peerID: "alternate", enabled: true)
        let descriptor = try #require(fixture.operations.first { $0.entity == .resource })
        let scalarIDs = Set(fixture.operations.filter { !$0.biometric && $0.entity != .resource }.map(\.id))
        for fragment in try Wire.fragments(for: descriptor) {
            _ = try await sync.receive(fragment, from: "alternate")
        }
        let pending = try await sync.pending(peerID: "alternate", includeBiometrics: false)
        #expect(Set(pending.map(\.id)) == scalarIDs)
        #expect(try await sync.pending(peerID: "peer").isEmpty)
        for operation in pending {
            for fragment in try Wire.fragments(for: operation) { _ = try await sync.receive(fragment, from: "alternate") }
        }
        #expect(try await sync.pending(peerID: "alternate").isEmpty)
        try await sync.configure(peerID: "new-phone", enabled: true)
        #expect(try await sync.pending(peerID: "new-phone", includeBiometrics: false).count == scalarIDs.count + 1)
        #expect(try await sync.audit(entity: .resource, id: descriptor.entityID).map(\.id) == [descriptor.id])
    }

    @Test(arguments: [false, true], [false, true])
    func queuedTargetEditSurvivesProjectionWithoutRecapture(editFirst: Bool, lowClock: Bool) async throws {
        let fixture = try await fixture()
        let artifact = try await artifact(fixture, label: "output")
        let (db, sync) = try await replica(fixture)
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let edit = Wire.Operation(stamp: .init(counter: lowClock ? 1 : artifact.operation.stamp.counter + 50,
            deviceID: "editor", operationID: "queued-edit"), entity: .utterance, entityID: artifact.output.id,
            field: "text", value: "user\0edit")
        if editFirst { try await sync.apply([edit], from: "peer") }
        try await install(artifact, on: sync, directory: directory)
        try await sync.publishResource(id: artifact.operation.entityID)
        if !editFirst { try await sync.apply([edit], from: "peer") }
        try await sync.publishResource(id: artifact.operation.entityID)
        #expect(try await UtteranceRepository(db).fetch(meetingId: fixture.meeting.id).first?.text == "user\0edit")
        #expect(try await sync.pending(peerID: "peer").isEmpty)
        #expect(try await db.reader.read {
            try String.fetchOne($0, sql: """
                SELECT operationID FROM automaticSyncRegister WHERE entity='utterance' AND entityID=? AND field='text'
                """, arguments: [AutomaticSyncRepository.canonicalID(artifact.output.id)])
        } == edit.id)
    }

    @Test(arguments: [false, true])
    func explicitClearDominatesInferredIdentityInBothOrders(clearFirst: Bool) async throws {
        let fixture = try await fixture()
        let artifact = try await artifact(fixture, label: "assigned-output")
        let (db, sync) = try await replica(fixture)
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clear = Wire.Operation(stamp: .init(counter: 1, deviceID: "editor", operationID: "clear"),
            entity: .utterance, entityID: artifact.output.id, field: "speakerId", value: nil, biometric: true)
        if clearFirst { try await sync.apply([clear], from: "peer") }
        try await install(artifact, on: sync, directory: directory)
        try await sync.publishResource(id: artifact.operation.entityID)
        if !clearFirst { try await sync.apply([clear], from: "peer") }
        #expect(try await UtteranceRepository(db).fetch(meetingId: fixture.meeting.id).first?.speakerId == nil)
        #expect(try await sync.pending(peerID: "peer").isEmpty)
    }

    @Test(arguments: [false, true])
    func competingPublicationsAndDescendantsConverge(reverse: Bool) async throws {
        let fixture = try await fixture()
        let a = try await artifact(fixture, label: "branch-a")
        let b = try await artifact(fixture, label: "branch-b")
        let winner = a.operation.entityID > b.operation.entityID ? a : b
        let loser = a.operation.entityID > b.operation.entityID ? b : a
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, childSender) = try await replica(fixture)
        try await install(loser, on: childSender, directory: directory)
        try await childSender.publishResource(id: loser.operation.entityID)
        let child = try await artifact(fixture, label: "losing-descendant", from: childSender, input: loser.revision)
        let (db, sync) = try await replica(fixture)
        // Metadata (including inferred identity) can precede either artifact.
        try await sync.apply(a.operations + b.operations + child.operations, from: "peer")
        try await install(child, on: sync, directory: directory)
        await #expect(throws: Wire.Failure.staleRevision) { try await sync.publishResource(id: child.operation.entityID) }
        let order = reverse ? [winner, loser, child] : [loser, child, winner]
        for candidate in order + order.reversed() {
            try await install(candidate, on: sync, directory: directory)
            try await sync.publishResource(id: candidate.operation.entityID)
        }
        #expect(try await sync.transcriptRevision(meetingID: fixture.meeting.id) == winner.revision)
        let rows = try await UtteranceRepository(db).fetch(meetingId: fixture.meeting.id)
        #expect(rows.count == 1 && rows.first?.id == winner.output.id && rows.first?.speakerId == fixture.original.speakerId)
        #expect(try await sync.pending(peerID: "peer").isEmpty)
        let descendant = try await artifact(fixture, label: "winning-descendant", from: sync, input: winner.revision)
        #expect(try await sync.transcriptRevision(meetingID: fixture.meeting.id) == descendant.revision)
        try await sync.publishResource(id: loser.operation.entityID)
        #expect(try await sync.transcriptRevision(meetingID: fixture.meeting.id) == descendant.revision)
        try await MeetingRepository(db).delete(id: fixture.meeting.id)
        #expect(try await db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM automaticSyncTranscriptRevision")
        } == 0)
    }

    @Test func competingPublicationCannotOverwriteNewerUserEdit() async throws {
        let fixture = try await fixture()
        let a = try await artifact(fixture, label: "branch-a")
        let b = try await artifact(fixture, label: "branch-b")
        let winner = a.operation.entityID > b.operation.entityID ? a : b
        let loser = a.operation.entityID > b.operation.entityID ? b : a
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (db, sync) = try await replica(fixture)
        try await install(loser, on: sync, directory: directory)
        try await sync.publishResource(id: loser.operation.entityID)
        try await db.writer.write {
            try $0.execute(sql: "UPDATE utterance SET text='protected' WHERE id=?", arguments: [loser.output.id])
        }
        try await install(winner, on: sync, directory: directory)
        await #expect(throws: Wire.Failure.staleRevision) { try await sync.publishResource(id: winner.operation.entityID) }
        #expect(try await UtteranceRepository(db).fetch(meetingId: fixture.meeting.id).first?.text == "protected")
        #expect(try await sync.pendingApplications(peerID: "peer").contains(winner.operation.entityID))
        let editedRevision = try await sync.transcriptRevision(meetingID: fixture.meeting.id)
        let fresh = try await artifact(fixture, label: "processed-edited-input", from: sync, input: editedRevision)
        await #expect(throws: Wire.Failure.staleRevision) { try await sync.publishResource(id: winner.operation.entityID) }
        #expect(try await sync.transcriptRevision(meetingID: fixture.meeting.id) == fresh.revision)
    }

    @Test func publicationRetryComparesExactUTF8() async throws {
        let fixture = try await fixture()
        let artifact = try await artifact(fixture, label: "é", from: fixture.sync)
        var changed = artifact.output
        changed.text = "e\u{301}"
        let retry = changed
        await #expect(throws: Wire.Failure.equivocation) {
            try await fixture.sync.publishTranscript(meetingID: fixture.meeting.id,
                expectedAudioSHA256: fixture.meeting.audioSHA256!, expectedRevision: fixture.revision,
                utterances: [retry], publicationID: "é", modelFingerprint: "model", preprocessing: "asr16k")
        }
    }

    @Test(arguments: ["unknown", "gap", "outside", "covered", "clear", "forged-omission", "forged-nonoverlap"])
    func identityInheritanceRequiresCompleteKnownCoverage(scenario: String) async throws {
        let fixture = try await fixture()
        let db = fixture.db, sync = fixture.sync
        let firstEnd = scenario == "gap" ? 400 : 500
        try await db.writer.write {
            try $0.execute(sql: "UPDATE utterance SET endMs=? WHERE id=?", arguments: [firstEnd, fixture.original.id])
        }
        let second = Utterance(meetingId: fixture.meeting.id,
            startMs: scenario == "forged-nonoverlap" ? 1_500 : 500,
            endMs: scenario == "forged-nonoverlap" ? 2_000 : 1_000, text: "second",
            speakerId: ["unknown", "forged-omission"].contains(scenario) ? nil : fixture.original.speakerId, originDeviceId: "source")
        try await UtteranceRepository(db).append(second)
        let input = try await sync.transcriptRevision(meetingID: fixture.meeting.id)
        let output = Utterance(meetingId: fixture.meeting.id, startMs: scenario == "outside" ? 100 : 0,
            endMs: scenario == "outside" ? 1_100 : 1_000, text: "replacement", originDeviceId: "worker")
        let targetID = output.id
        if scenario == "clear" {
            try await sync.apply([.init(stamp: .init(counter: 9_000, deviceID: "editor", operationID: "explicit-clear"),
                entity: .utterance, entityID: targetID, field: "speakerId", value: nil, biometric: true)], from: "peer")
        }
        if scenario.hasPrefix("forged") {
            var mappings = [AutomaticSyncRepository.TranscriptMapping(sourceID: fixture.original.id, sourceRevision: 1,
                sourceStartMs: 0, sourceEndMs: firstEnd, targetID: targetID)]
            if scenario == "forged-nonoverlap" {
                mappings.append(.init(sourceID: second.id, sourceRevision: 1, sourceStartMs: 1_500,
                                      sourceEndMs: 2_000, targetID: targetID))
            }
            let payload = AutomaticSyncRepository.TranscriptPublication(id: scenario, meetingID: fixture.meeting.id,
                audioSHA256: fixture.meeting.audioSHA256!, inputRevision: input, utterances: [output], mappings: mappings)
            let bytes = try Wire.encode(payload)
            let id = try await sync.registerResource(.init(kind: .transcript, meetingID: fixture.meeting.id,
                sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count),
                modelFingerprint: "model", preprocessing: "asr16k", inputRevision: input))
            await #expect(throws: Wire.Failure.invalid) {
                try await db.writer.write { try AutomaticSyncRepository.applyTranscript($0, payload: payload, resourceID: id) }
            }
            #expect(try await UtteranceRepository(db).fetch(meetingId: fixture.meeting.id).count == 2)
        } else {
            _ = try await sync.publishTranscript(meetingID: fixture.meeting.id,
                expectedAudioSHA256: fixture.meeting.audioSHA256!, expectedRevision: input, utterances: [output],
                publicationID: scenario, modelFingerprint: "model", preprocessing: "asr16k")
            let rows = try await UtteranceRepository(db).fetch(meetingId: fixture.meeting.id)
            #expect(rows.count == 1)
            #expect(rows.first?.speakerId == (scenario == "covered" ? fixture.original.speakerId : nil))
        }
    }

    @Test func alternateByteSourceRetainsReceiptAndMissingFileRemainsDownloadable() async throws {
        let fixture = try await fixture()
        let (db, sync) = try await replica(fixture)
        try await sync.configure(peerID: "alternate", enabled: true)
        let bytes = Data("verified audio fixture".utf8)
        let descriptor = Wire.Resource(kind: .audio, meetingID: fixture.meeting.id,
            sha256: IncrementalSHA256.hex(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count))
        let id = try AutomaticSyncRepository.resourceID(descriptor)
        let operation = Wire.Operation(stamp: .init(counter: 10_000, deviceID: "original", operationID: "audio-descriptor"),
            entity: .resource, entityID: id, field: "descriptor", value: String(decoding: try Wire.encode(descriptor), as: UTF8.self))
        try await sync.apply([operation], from: "peer")
        try await sync.apply([operation], from: "alternate")
        try await db.writer.write {
            try $0.execute(sql: "UPDATE meeting SET audioSHA256=NULL WHERE id=?", arguments: [fixture.meeting.id])
        }
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = AutomaticSyncResourceTransfer(db, directory: directory)
        let chunk = AutomaticSyncResourceWire.Chunk(resourceID: id, offset: 0, total: Int64(bytes.count), bytes: bytes)
        #expect(try await transfer.receive(chunk, from: "alternate") == bytes.count)
        #expect(try await sync.pendingApplications(peerID: "alternate") == [id])
        #expect(try await sync.resourcesNeedingDownload(from: "alternate").isEmpty)
        let file = directory.appendingPathComponent(descriptor.sha256 + ".m4a")
        try FileManager.default.removeItem(at: file)
        #expect(try await sync.resourcesNeedingDownload(from: "peer") == [id])
        #expect(try await sync.resourcesNeedingDownload(from: "alternate") == [id])
        #expect(try await sync.reconcileVerifiedResources(from: "alternate", includeBiometrics: false).isEmpty)
        #expect(try await transfer.progress(resourceID: id, from: "alternate") == 0)
        _ = try await transfer.receive(chunk, from: "alternate")
        try await sync.adoptAudioResource(id: id)
        let imports = try await sync.verifiedAudioImports()
        #expect(imports.count == 1 && imports.first?.peerID == "alternate" && imports.first?.operationID == operation.id)
        #expect(try await sync.resourcesNeedingDownload(from: "peer").isEmpty)
    }

    @Test func missingTranscriptBytesAreUnavailableNotInvalidAndCanRedownload() async throws {
        let fixture = try await fixture()
        let artifact = try await artifact(fixture, label: "missing-file")
        let (_, sync) = try await replica(fixture)
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await install(artifact, on: sync, directory: directory)
        try await sync.configure(peerID: "alternate", enabled: true)
        try await sync.apply([artifact.operation], from: "alternate")
        let hash = try #require(try await sync.resource(id: artifact.operation.entityID)).sha256
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for child in children {
            let file = child.appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        await #expect(throws: Wire.Failure.resourceUnavailable) { try await sync.publishResource(id: artifact.operation.entityID) }
        #expect(try await sync.resourcesNeedingDownload(from: "alternate") == [artifact.operation.entityID])
        #expect(try await sync.reconcileVerifiedResources(from: "peer", includeBiometrics: true).isEmpty)
        try await install(artifact, on: sync, directory: directory)
        #expect(try await sync.reconcileVerifiedResources(from: "alternate", includeBiometrics: false).first?.status == .applied)
        #expect(try await sync.transcriptRevision(meetingID: fixture.meeting.id) == artifact.revision)
    }
}
