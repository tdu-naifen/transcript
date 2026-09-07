import AVFoundation
import CryptoKit
import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

/// SQLite/channel integration only: no sockets, trust store, audio capture or models.
@MainActor
final class AutomaticSyncIntegrationQATests: XCTestCase {
    private typealias Wire = AutomaticSyncRepository.Wire
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testRepositoryBackedChannelsExchangeBothDirectionsAndPersistAcknowledgements() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let leftPeer = peer(1), rightPeer = peer(2)
        let leftID = AutomaticSyncChannel.peerID(leftPeer)
        let rightID = AutomaticSyncChannel.peerID(rightPeer)
        var leftOperationIDs = Set<String>()
        var rightOperationIDs = Set<String>()
        do {
            let a = try AppDatabase.onDisk(directory: root.appendingPathComponent("a"))
            let b = try AppDatabase.onDisk(directory: root.appendingPathComponent("b"))
            let left = AutomaticSyncRepository(a), right = AutomaticSyncRepository(b)
            try await left.configure(peerID: rightID, enabled: true)
            try await right.configure(peerID: leftID, enabled: true)
            try await MeetingRepository(a).insert(meeting("left", title: "Left before edit"))
            try await MeetingRepository(b).insert(meeting("right", title: "Right before edit"))
            try await MeetingRepository(a).rename(id: "left", title: String(repeating: "左🙂", count: 900),
                                                  deviceId: "a", now: instant)
            try await MeetingRepository(b).rename(id: "right", title: "Right local", deviceId: "b", now: instant)
            leftOperationIDs = Set(try await left.pending(peerID: rightID, limit: 256).map(\.id))
            rightOperationIDs = Set(try await right.pending(peerID: leftID, limit: 256).map(\.id))
            XCTAssertFalse(leftOperationIDs.isEmpty)
            XCTAssertFalse(rightOperationIDs.isEmpty)
            let link = QueuedLink()
            let first = AutomaticSyncChannel(
                storage: .repository(left, peer: rightPeer, isTrusted: { true }),
                send: { link.toRight.append($0) }, onFailure: { link.failures += 1 }
            )
            let second = AutomaticSyncChannel(
                storage: .repository(right, peer: leftPeer, isTrusted: { true }),
                send: { link.toLeft.append($0) }, onFailure: { link.failures += 1 }
            )
            defer { first.stop(); second.stop() }
            try await first.negotiate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if !link.toRight.isEmpty {
                    let message = link.toRight.removeFirst()
                    try await verifyCommittedAcknowledgement(message, repository: left,
                                                             ids: rightOperationIDs, link: link)
                    try await second.handle(message)
                }
                if !link.toLeft.isEmpty {
                    let message = link.toLeft.removeFirst()
                    try await verifyCommittedAcknowledgement(message, repository: right,
                                                             ids: leftOperationIDs, link: link)
                    try await first.handle(message)
                }
                let pendingLeft = try await left.pending(peerID: rightID)
                let pendingRight = try await right.pending(peerID: leftID)
                if pendingLeft.isEmpty && pendingRight.isEmpty { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(link.failures, 0)
            XCTAssertEqual(link.acknowledged, leftOperationIDs.union(rightOperationIDs))
            let receivedLeft = try await MeetingRepository(b).fetch(id: "left")
            let receivedRight = try await MeetingRepository(a).fetch(id: "right")
            XCTAssertEqual(receivedLeft?.title, String(repeating: "左🙂", count: 900))
            XCTAssertEqual(receivedRight?.title, "Right local")
            let leftAudit = try await left.audit(entity: .meeting, id: "right")
            let rightAudit = try await right.audit(entity: .meeting, id: "left")
            XCTAssertEqual(Set(leftAudit.map(\.id)), rightOperationIDs)
            XCTAssertEqual(Set(rightAudit.map(\.id)), leftOperationIDs)
        }
        let reopenedA = AutomaticSyncRepository(try AppDatabase.onDisk(directory: root.appendingPathComponent("a")))
        let reopenedB = AutomaticSyncRepository(try AppDatabase.onDisk(directory: root.appendingPathComponent("b")))
        let pendingA = try await reopenedA.pending(peerID: rightID)
        let pendingB = try await reopenedB.pending(peerID: leftID)
        XCTAssertTrue(pendingA.isEmpty, "Acknowledgements must survive repository restart")
        XCTAssertTrue(pendingB.isEmpty, "Remote commits must not produce echo operations")
        let auditA = try await reopenedA.audit(entity: .meeting, id: "right")
        let auditB = try await reopenedB.audit(entity: .meeting, id: "left")
        XCTAssertEqual(Set(auditA.map(\.id)), rightOperationIDs)
        XCTAssertEqual(Set(auditB.map(\.id)), leftOperationIDs)
    }

    func testOfflineProductionEditsConvergeUnderSeededPermutationAndDuplicates() async throws {
        for seed in 1...12 {
            let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
            let left = try await configured(a), right = try await configured(b)
            try await MeetingRepository(a).insert(meeting("shared", title: "Original"))
            let initial = try await left.pending(peerID: "peer", limit: 256)
            try await deliver(initial, to: right)
            try await left.acknowledge(peerID: "peer", operationIDs: initial.map(\.id))
            try await MeetingRepository(a).rename(id: "shared", title: "Left first", deviceId: "a", now: instant)
            try await MeetingRepository(a).rename(id: "shared", title: "Left final", deviceId: "a", now: instant)
            try await MeetingRepository(b).rename(id: "shared", title: "Right", deviceId: "b",
                                                  now: instant.addingTimeInterval(1_000_000))
            try await MeetingRepository(b).setEmoji(id: "shared", emoji: "🎙️", deviceId: "b", now: instant)
            let leftEdits = try await left.pending(peerID: "peer", limit: 256)
            let rightEdits = try await right.pending(peerID: "peer", limit: 256)
            XCTAssertEqual(leftEdits.filter { $0.field == "title" }.count, 2)
            XCTAssertEqual(rightEdits.filter { $0.field == "title" }.count, 1)
            XCTAssertEqual(rightEdits.filter { $0.field == "emoji" }.count, 1)
            var generator = SeededGenerator(state: UInt64(seed))
            try await deliver((rightEdits + rightEdits + initial).shuffled(using: &generator), to: left)
            try await deliver((leftEdits + initial + leftEdits).shuffled(using: &generator), to: right)
            let expectedTitle = try XCTUnwrap((leftEdits + rightEdits)
                .filter { $0.field == "title" }.max { $0.stamp < $1.stamp }?.value)
            XCTAssertEqual(expectedTitle, "Left final", "Future wall time must not beat the higher logical counter")
            let materializedA = try await MeetingRepository(a).fetch(id: "shared")
            let materializedB = try await MeetingRepository(b).fetch(id: "shared")
            XCTAssertEqual(materializedA?.title, expectedTitle, "seed \(seed)")
            XCTAssertEqual(materializedB?.title, expectedTitle, "seed \(seed)")
            XCTAssertEqual(materializedA?.emoji, "🎙️", "Independent field must survive")
            XCTAssertEqual(materializedB?.emoji, "🎙️")
            let valuesA = try await left.values(entity: .meeting, id: "shared")
            let valuesB = try await right.values(entity: .meeting, id: "shared")
            XCTAssertEqual(valuesA, valuesB, "seed \(seed)")
            let expectedIDs = Set((initial + leftEdits + rightEdits).map(\.id))
            let auditA = try await left.audit(entity: .meeting, id: "shared")
            let auditB = try await right.audit(entity: .meeting, id: "shared")
            XCTAssertEqual(Set(auditA.map(\.id)), expectedIDs)
            XCTAssertEqual(Set(auditB.map(\.id)), expectedIDs)
            XCTAssertEqual(auditA.count, expectedIDs.count, "Duplicates cannot inflate history")
            let outgoingA = try await left.pending(peerID: "peer", limit: 256)
            let outgoingB = try await right.pending(peerID: "peer", limit: 256)
            XCTAssertEqual(Set(outgoingA.map(\.id)), Set(leftEdits.map(\.id)), "No remote echo")
            XCTAssertEqual(Set(outgoingB.map(\.id)), Set(rightEdits.map(\.id)), "No remote echo")
        }
    }

    func testInterruptedReceiveLostAcknowledgementAndDeleteReplaySurviveRestart() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDB = try AppDatabase.onDisk(directory: root.appendingPathComponent("source"))
        let source = try await configured(sourceDB)
        try await MeetingRepository(sourceDB).insert(meeting("durable", title: "Before disconnect"))
        let creation = try await source.pending(peerID: "peer", limit: 256)
        let targetPath = root.appendingPathComponent("target")
        do {
            let target = try await configured(AppDatabase.onDisk(directory: targetPath))
            try await deliver(creation, to: target)
        }
        try await source.acknowledge(peerID: "peer", operationIDs: creation.map(\.id))
        let editedTitle = String(repeating: "Persistent edit 界", count: 800)
        try await MeetingRepository(sourceDB).rename(id: "durable", title: editedTitle, deviceId: "source", now: instant)
        let edits = try await source.pending(peerID: "peer")
        let edit = try XCTUnwrap(edits.first)
        XCTAssertEqual(edits.count, 1)
        let fragments = try Wire.fragments(for: edit)
        XCTAssertGreaterThan(fragments.count, 2)
        do {
            let targetDB = try AppDatabase.onDisk(directory: targetPath)
            let target = AutomaticSyncRepository(targetDB)
            let receipt = try await target.receive(fragments[0], from: "peer")
            XCTAssertNil(receipt)
            let unchanged = try await MeetingRepository(targetDB).fetch(id: "durable")
            XCTAssertEqual(unchanged?.title, "Before disconnect")
        }
        do {
            let targetDB = try AppDatabase.onDisk(directory: targetPath)
            let target = AutomaticSyncRepository(targetDB)
            // Resume without replaying fragment zero: reassembly itself must be durable.
            for (index, fragment) in fragments.dropFirst().enumerated() {
                let receipt = try await target.receive(fragment, from: "peer")
                XCTAssertEqual(receipt, index == fragments.count - 2 ? edit.id : nil)
            }
            let committed = try await MeetingRepository(targetDB).fetch(id: "durable")
            XCTAssertEqual(committed?.title, editedTitle)
        }
        do {
            let target = AutomaticSyncRepository(try AppDatabase.onDisk(directory: targetPath))
            // The commit succeeded but its ACK was lost; a whole-operation retry is safe.
            try await deliver([edit, edit], to: target)
            let audit = try await target.audit(entity: .meeting, id: "durable")
            XCTAssertEqual(audit.filter { $0.id == edit.id }.count, 1)
            let echo = try await target.pending(peerID: "peer")
            XCTAssertTrue(echo.isEmpty)
        }
        let unacknowledged = try await source.pending(peerID: "peer")
        XCTAssertEqual(unacknowledged.map(\.id), [edit.id])
        try await source.acknowledge(peerID: "peer", operationIDs: [edit.id])
        var concurrentEdits: [Wire.Operation] = []
        do {
            let targetDB = try AppDatabase.onDisk(directory: targetPath)
            try await MeetingRepository(targetDB).rename(id: "durable", title: "Offline concurrent 1",
                                                         deviceId: "target", now: instant)
            try await MeetingRepository(targetDB).rename(id: "durable", title: "Offline concurrent 2",
                                                         deviceId: "target", now: instant)
            concurrentEdits = try await AutomaticSyncRepository(targetDB).pending(peerID: "peer")
        }
        try await MeetingRepository(sourceDB).delete(id: "durable")
        let deletion = try await source.pending(peerID: "peer")
        XCTAssertTrue(deletion.contains { $0.entity == .meeting && $0.isDelete })
        let deleteClock = try XCTUnwrap(deletion.first { $0.entity == .meeting && $0.isDelete }?.stamp.counter)
        let concurrentClock = try XCTUnwrap(concurrentEdits.map(\.stamp.counter).max())
        XCTAssertGreaterThan(concurrentClock, deleteClock, "Exercise delete versus a higher-clock offline edit")
        try await deliver(concurrentEdits, to: source)
        let sourceRemoved = try await MeetingRepository(sourceDB).fetch(id: "durable")
        XCTAssertNil(sourceRemoved, "Delete is remove-wins, not just a field LWW register")
        do {
            let target = AutomaticSyncRepository(try AppDatabase.onDisk(directory: targetPath))
            try await deliver(deletion, to: target)
        }
        let reopenedDB = try AppDatabase.onDisk(directory: targetPath)
        let reopened = AutomaticSyncRepository(reopenedDB)
        try await deliver((creation + [edit] + concurrentEdits).reversed(), to: reopened)
        let removed = try await MeetingRepository(reopenedDB).fetch(id: "durable")
        let tombstone = try await reopened.isDeleted(entity: .meeting, id: "durable")
        XCTAssertNil(removed, "Old fields must never resurrect a deleted meeting")
        XCTAssertTrue(tombstone)
    }

    func testProductionSpeakerMergeReplicatesRekeyedAndRemovedMemberships() async throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await configured(a), right = try await configured(b)
        try await left.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await right.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let speakers = SpeakerRepository(a)
        for id in ["keep", "absorb"] {
            try await speakers.upsert(Speaker(id: id, anonymousName: id, colorIndex: 1, originDeviceId: "a"))
        }
        for id in ["only-absorbed", "both-linked"] {
            try await MeetingRepository(a).insert(meeting(id, title: id))
            try await speakers.assignDisplayIndex(meetingId: id, speakerId: "absorb", displayIndex: 0,
                                                   deviceId: "a", now: instant)
        }
        try await speakers.assignDisplayIndex(meetingId: "both-linked", speakerId: "keep", displayIndex: 1,
                                               deviceId: "a", now: instant)
        let initial = try await left.pending(peerID: "peer", limit: 256)
        try await deliver(initial.reversed(), to: right)
        try await left.acknowledge(peerID: "peer", operationIDs: initial.map(\.id))
        try await speakers.mergeSpeakers(keep: "keep", absorb: "absorb", deviceId: "a", now: instant)
        let merged = try await left.pending(peerID: "peer", limit: 256)
        try await deliver((merged + merged).reversed(), to: right)
        for meetingID in ["only-absorbed", "both-linked"] {
            let localMembers = try await speakers.speakers(inMeeting: meetingID)
            let remoteMembers = try await SpeakerRepository(b).speakers(inMeeting: meetingID)
            XCTAssertEqual(localMembers.map(\.speaker.id), ["keep"])
            XCTAssertEqual(remoteMembers.map(\.speaker.id), ["keep"],
                           "Production merge must replicate membership key updates for \(meetingID)")
        }
        let absorbedRemote = try await SpeakerRepository(b).fetch(id: "absorb")
        XCTAssertNil(absorbedRemote)
        let originalOnlyMembership = try XCTUnwrap(initial.first {
            $0.entity == .association && $0.field == "meetingId" && $0.value == "only-absorbed"
        }?.entityID)
        XCTAssertTrue(merged.contains {
            $0.entity == .association && $0.entityID == originalOnlyMembership && $0.isDelete
        }, "Changing membership identity must retire its immutable old ID")
        let replacements = merged.filter {
            $0.entity == .association && $0.field == "meetingId" && $0.value == "only-absorbed"
        }
        XCTAssertEqual(replacements.count, 1)
        XCTAssertNotEqual(replacements.first?.entityID, originalOnlyMembership,
                          "Re-add requires a new immutable membership ID")
        try await deliver(initial, to: right)
        let afterOldReplay = try await SpeakerRepository(b).speakers(inMeeting: "only-absorbed")
        XCTAssertEqual(afterOldReplay.map(\.speaker.id), ["keep"], "Old membership replay cannot undo merge")
        let echo = try await right.pending(peerID: "peer")
        XCTAssertTrue(echo.isEmpty)
    }

    func testRepositoryChannelAdapterRechecksTrustAndDisablement() async throws {
        let db = try AppDatabase.inMemory()
        let sync = AutomaticSyncRepository(db)
        let remote = peer(9)
        let id = AutomaticSyncChannel.peerID(remote)
        try await sync.configure(peerID: id, enabled: true)
        try await MeetingRepository(db).insert(meeting("private", title: "Not discoverable"))
        var trusted = false
        let storage = AutomaticSyncChannel.Storage.repository(sync, peer: remote, isTrusted: { trusted })
        var sends = 0
        let channel = AutomaticSyncChannel(storage: storage, send: { _ in sends += 1 }, onFailure: { XCTFail() })
        defer { channel.stop() }
        try await channel.negotiate()
        XCTAssertEqual(sends, 0)
        await expectFailure(.disabled) { _ = try await storage.pending() }
        trusted = true
        let enabled = try await storage.isEnabled()
        XCTAssertTrue(enabled)
        let pending = try await sync.pending(peerID: id)
        let operation = try XCTUnwrap(pending.first)
        let fragment = try XCTUnwrap(try Wire.fragments(for: operation).first)
        trusted = false
        await expectFailure(.disabled) { _ = try await storage.receive(fragment) }
        await expectFailure(.disabled) { try await storage.acknowledge(operation.id) }
        trusted = true
        try await sync.configure(peerID: id, enabled: false)
        await expectFailure(.disabled) { _ = try await storage.pending() }
        await expectFailure(.disabled) { _ = try await storage.receive(fragment) }
    }

    func testSupportedEmbeddedNULTranscriptRoundTripsWithoutPoisoningOutbox() async throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await configured(a), right = try await configured(b)
        try await MeetingRepository(a).insert(meeting("nul-text", title: "Supported stored text"))
        let utterance = Utterance(id: "nul-utterance", meetingId: "nul-text", startMs: 0, endMs: 1000,
                                  text: "abc\u{0}AFTER", originDeviceId: "a")
        try await UtteranceRepository(a).append(utterance)
        let stored = try await UtteranceRepository(a).fetch(meetingId: "nul-text")
        XCTAssertEqual(stored.first?.text, utterance.text, "Establish the production repository accepts this text")
        let outgoing = try await left.pending(peerID: "peer", limit: 256)
        try await deliver(outgoing, to: right)
        let received = try await UtteranceRepository(b).fetch(meetingId: "nul-text")
        XCTAssertEqual(received.first?.text, utterance.text,
                       "Sync must preserve supported text, not permanently poison the sender outbox")
        try await left.acknowledge(peerID: "peer", operationIDs: outgoing.map(\.id))
        let remaining = try await left.pending(peerID: "peer")
        let echo = try await right.pending(peerID: "peer")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(echo.isEmpty)
    }

    func testWithheldBiometricBacklogCannotStarveProductionTitleEdit() async throws {
        let db = try AppDatabase.inMemory()
        let sync = AutomaticSyncRepository(db)
        let remote = peer(7)
        let peerID = AutomaticSyncChannel.peerID(remote)
        try await sync.configure(peerID: peerID, enabled: true)
        try await MeetingRepository(db).insert(meeting("backlog", title: "Before biometric backlog"))
        try await SpeakerRepository(db).upsert(Speaker(
            id: "backlog-speaker", anonymousName: "Synthetic fixture", colorIndex: 0, originDeviceId: "local"
        ))
        let baseline = try await sync.pending(peerID: peerID, limit: 256)
        try await sync.acknowledge(peerID: peerID, operationIDs: baseline.map(\.id))
        // Synthetic payload identities exercise pagination only, not biometric functionality.
        let embedding = SpeakerEmbedding(id: "backlog-embedding", speakerId: "backlog-speaker",
                                         floats: [1], originDeviceId: "local", modelIdentifier: "synthetic-model")
        try await SpeakerRepository(db).addEmbedding(embedding)
        try await sync.setVoiceprintConsent(peerID: peerID, state: .allowed)
        var registered: Set<String> = []
        for index in 0..<64 {
            registered.insert(try await sync.registerVoiceprint(
                embeddingID: embedding.id, preprocessing: "synthetic-\(index)"
            ))
        }
        try await MeetingRepository(db).rename(id: "backlog", title: "Must not starve",
                                               deviceId: "local", now: instant)
        let allPending = try await sync.pending(peerID: peerID, limit: 256)
        let biometric = allPending.filter(\.biometric)
        let descriptors = biometric.filter { $0.entity == .resource }
        let descriptorIDs = Set(descriptors.map(\.entityID))
        XCTAssertEqual(registered.count, 64)
        XCTAssertTrue(registered.isSubset(of: descriptorIDs))
        let opaqueIDs = descriptorIDs.subtracting(registered)
        XCTAssertEqual(opaqueIDs.count, 1, "The original unknown-provenance artifact must also be preserved")
        let opaque = try await sync.resource(id: XCTUnwrap(opaqueIDs.first))
        XCTAssertNil(opaque?.preprocessing)
        XCTAssertEqual(descriptors.count, descriptorIDs.count)
        let identityMetadata = biometric.filter { $0.entity != .resource }
        XCTAssertEqual(identityMetadata.count, 4)
        XCTAssertTrue(identityMetadata.allSatisfy {
            $0.entity == .speaker && $0.entityID == "backlog-speaker"
        })
        XCTAssertEqual(Set(identityMetadata.map(\.field)),
                       Set(["displayName", "anonymousName", "colorIndex", "createdAt"]))
        let title = try XCTUnwrap(allPending.first { $0.entity == .meeting && $0.field == "title" })
        let storage = AutomaticSyncChannel.Storage.repository(sync, peer: remote, isTrusted: { true })
        let transmissible = try await storage.pending()
        XCTAssertTrue(transmissible.allSatisfy { !$0.biometric },
                      "No biometric export without negotiated bilateral consent")
        XCTAssertTrue(transmissible.contains { $0.id == title.id },
                      "Filter forbidden resources before applying page limit; blocked biometrics must not starve metadata")
    }

    func testProductionArtifactCaptureVerifiedBytesAndStalePublication() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AppDatabase.onDisk(directory: root.appendingPathComponent("a"))
        let b = try AppDatabase.onDisk(directory: root.appendingPathComponent("b"))
        let left = try await configured(a), right = try await configured(b)
        try await MeetingRepository(a).insert(meeting("analysis", title: "Input"))
        try await UtteranceRepository(a).append(Utterance(
            id: "input", meetingId: "analysis", startMs: 0, endMs: 1000, text: "First input",
            originDeviceId: "a"
        ))
        let revision = try await left.transcriptRevision(meetingID: "analysis")
        let draft = AnalysisResultDraft(id: "artifact", meetingId: "analysis", kind: .qa,
                                         payloadJSON: "{\"answer\":\"fixture\"}", producedByDeviceId: "a",
                                         producedAt: instant)
        _ = try await AnalysisResultRepository(a).record(
            draft, inputRevision: revision, modelFingerprint: "qa-fixture-model", preprocessing: "qa-v1"
        )
        let outgoing = try await left.pending(peerID: "peer", limit: 256)
        let resourceOperation = try XCTUnwrap(outgoing.first { $0.entity == .resource })
        let bytesValue = try await left.resourceBytes(id: resourceOperation.entityID, for: "peer")
        let bytes = try XCTUnwrap(bytesValue)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisResultDraft.self, from: bytes), draft)
        try await deliver(outgoing.reversed(), to: right)
        let descriptorValue = try await right.resource(id: resourceOperation.entityID)
        let descriptor = try XCTUnwrap(descriptorValue)
        XCTAssertEqual(descriptor.inputRevision, revision)
        XCTAssertEqual(descriptor.byteCount, Int64(bytes.count))
        await expectFailure(.resourceUnavailable) { try await right.publishResource(id: resourceOperation.entityID) }
        let source = root.appendingPathComponent("artifact-source")
        let destination = root.appendingPathComponent("verified")
        var corrupt = bytes
        corrupt[corrupt.startIndex] ^= 1
        try corrupt.write(to: source)
        await expectFailure(.hashMismatch) {
            _ = try await right.installResource(id: resourceOperation.entityID, from: source, directory: destination)
        }
        let rejectedFiles = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertTrue(rejectedFiles.isEmpty, "Failed hash verification must leave no eligible bytes")
        try bytes.write(to: source)
        let installed = try await right.installResource(id: resourceOperation.entityID, from: source, directory: destination)
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
        XCTAssertEqual(installed.lastPathComponent, descriptor.sha256)
        try await right.publishResource(id: resourceOperation.entityID)
        let publication = try await right.publishedResource(meetingID: "analysis", kind: .analysis)
        XCTAssertEqual(publication, resourceOperation.entityID)
        let materialized = try await AnalysisResultRepository(b).latest(meetingId: "analysis", kind: .qa)
        XCTAssertEqual(materialized?.draft, draft, "Publication must reach the production analysis repository")
        try await left.acknowledge(peerID: "peer", operationIDs: outgoing.map(\.id))
        try await UtteranceRepository(a).append(Utterance(
            id: "new-input", meetingId: "analysis", startMs: 1000, endMs: 2000,
            text: "New input invalidates derived output", originDeviceId: "a"
        ))
        try await deliver(try await left.pending(peerID: "peer", limit: 256), to: right)
        await expectFailure(.staleRevision) { try await right.publishResource(id: resourceOperation.entityID) }
        let stale = try await right.publishedResource(meetingID: "analysis", kind: .analysis)
        let retained = try await right.resource(id: resourceOperation.entityID)
        XCTAssertNil(stale)
        XCTAssertEqual(retained, descriptor, "Stale immutable history remains addressable")
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
    }

    func testResourceChannelsTransferCapturedArtifactsAndRejectCorruptedBytes() async throws {
        for corruptOutbound in [false, true] {
            let root = fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let a = try AppDatabase.onDisk(directory: root.appendingPathComponent("a"))
            let b = try AppDatabase.onDisk(directory: root.appendingPathComponent("b"))
            let left = AutomaticSyncRepository(a), right = AutomaticSyncRepository(b)
            let leftPeer = peer(31), rightPeer = peer(32)
            let leftPeerID = AutomaticSyncChannel.peerID(leftPeer)
            let rightPeerID = AutomaticSyncChannel.peerID(rightPeer)
            try await left.configure(peerID: rightPeerID, enabled: true)
            try await right.configure(peerID: leftPeerID, enabled: true)
            let leftDraft = try await captureArtifact(in: a, sync: left, id: "left-bytes")
            let rightDraft = try await captureArtifact(in: b, sync: right, id: "right-bytes")
            let leftOperations = try await left.pending(peerID: rightPeerID, limit: 256)
            let rightOperations = try await right.pending(peerID: leftPeerID, limit: 256)
            let leftID = try XCTUnwrap(leftOperations.first { $0.entity == .resource }?.entityID)
            let rightID = try XCTUnwrap(rightOperations.first { $0.entity == .resource }?.entityID)
            try await deliver(leftOperations, to: right, from: leftPeerID)
            try await deliver(rightOperations, to: left, from: rightPeerID)
            try await left.acknowledge(peerID: rightPeerID, operationIDs: leftOperations.map(\.id))
            try await right.acknowledge(peerID: leftPeerID, operationIDs: rightOperations.map(\.id))
            let leftBytesValue = try await left.resourceBytes(id: leftID, for: rightPeerID)
            let rightBytesValue = try await right.resourceBytes(id: rightID, for: leftPeerID)
            let leftBytes = try XCTUnwrap(leftBytesValue), rightBytes = try XCTUnwrap(rightBytesValue)
            XCTAssertGreaterThan(leftBytes.count, 768)
            let leftDirectory = root.appendingPathComponent("received-left")
            let rightDirectory = root.appendingPathComponent("received-right")
            let leftTransfer = AutomaticSyncResourceTransfer(a, directory: leftDirectory)
            let rightTransfer = AutomaticSyncResourceTransfer(b, directory: rightDirectory)
            let link = QueuedLink()
            var corrupted = false
            let first = AutomaticSyncResourceChannel(
                storage: .repository(database: a, peer: rightPeer, audioDirectory: leftDirectory,
                                     isTrusted: { true }, peerAllowsVoiceprints: { false }),
                send: { inner in
                    var message = try AutomaticSyncResourceWire.decode(Data(try XCTUnwrap(inner.value).utf8))
                    if corruptOutbound, !corrupted, var chunk = message.chunk,
                       chunk.resourceID == leftID, chunk.offset == 0 {
                        chunk.bytes[chunk.bytes.startIndex] ^= 1
                        message.chunk = chunk
                        corrupted = true
                        link.toRight.append(.init(type: AutomaticSyncResourceWire.messageType,
                                                   value: String(decoding: try Wire.encode(message), as: UTF8.self)))
                    } else {
                        link.toRight.append(inner)
                    }
                },
                onFailure: { link.failures += 1 }
            )
            let second = AutomaticSyncResourceChannel(
                storage: .repository(database: b, peer: leftPeer, audioDirectory: rightDirectory,
                                     isTrusted: { true }, peerAllowsVoiceprints: { false }),
                send: { link.toLeft.append($0) }, onFailure: { link.failures += 1 }
            )
            defer { first.stop(); second.stop() }
            let unpublished = try await right.publishedResource(meetingID: leftDraft.meetingId, kind: .analysis)
            XCTAssertNil(unpublished, "Metadata delivery/ACK cannot stand in for verified resource bytes")
            try await first.negotiate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if link.failures > 0 { break }
                if !link.toRight.isEmpty { try await second.handle(link.toRight.removeFirst()) }
                if link.failures > 0 { break }
                if !link.toLeft.isEmpty { try await first.handle(link.toLeft.removeFirst()) }
                if link.failures > 0 { break }
                let leftPublished = try await left.publishedResource(meetingID: rightDraft.meetingId, kind: .analysis)
                let rightPublished = try await right.publishedResource(meetingID: leftDraft.meetingId, kind: .analysis)
                if leftPublished == rightID && rightPublished == leftID { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let descriptorValue = try await right.resource(id: leftID)
            let descriptor = try XCTUnwrap(descriptorValue)
            let rightTarget = rightDirectory.appendingPathComponent(descriptor.sha256)
            if corruptOutbound {
                XCTAssertTrue(corrupted, "The test must actually perturb an in-flight chunk")
                XCTAssertEqual(link.failures, 1, "A hash mismatch must fail the receiver channel")
                let published = try await right.publishedResource(meetingID: leftDraft.meetingId, kind: .analysis)
                let result = try await AnalysisResultRepository(b).latest(meetingId: leftDraft.meetingId, kind: .qa)
                XCTAssertNil(published)
                XCTAssertNil(result, "Corrupted output cannot enter the production analysis repository")
                XCTAssertFalse(FileManager.default.fileExists(atPath: rightTarget.path))
                let progress = try await rightTransfer.progress(resourceID: leftID, from: leftPeerID)
                XCTAssertLessThan(progress, Int64(leftBytes.count), "Failed bytes cannot receive a complete receipt")
            } else {
                XCTAssertEqual(link.failures, 0)
                let receivedRight = try await AnalysisResultRepository(b).latest(meetingId: leftDraft.meetingId, kind: .qa)
                let receivedLeft = try await AnalysisResultRepository(a).latest(meetingId: rightDraft.meetingId, kind: .qa)
                XCTAssertEqual(receivedRight?.draft, leftDraft)
                XCTAssertEqual(receivedLeft?.draft, rightDraft)
                XCTAssertEqual(try Data(contentsOf: rightTarget), leftBytes)
                let rightDescriptorValue = try await left.resource(id: rightID)
                let rightDescriptor = try XCTUnwrap(rightDescriptorValue)
                XCTAssertEqual(try Data(contentsOf: leftDirectory.appendingPathComponent(rightDescriptor.sha256)), rightBytes)
                let receivedOffset = try await rightTransfer.progress(resourceID: leftID, from: leftPeerID)
                XCTAssertEqual(receivedOffset, Int64(leftBytes.count))
                let restartedDB = try AppDatabase.onDisk(directory: root.appendingPathComponent("b"))
                let restartedTransfer = AutomaticSyncResourceTransfer(restartedDB, directory: rightDirectory)
                let persistedOffset = try await restartedTransfer.progress(resourceID: leftID, from: leftPeerID)
                XCTAssertEqual(persistedOffset, Int64(leftBytes.count))
                let replayValue = try await leftTransfer.chunk(resourceID: leftID, offset: 0, for: rightPeerID)
                let replay = try XCTUnwrap(replayValue)
                let duplicateReceipt = try await restartedTransfer.receive(replay, from: leftPeerID)
                XCTAssertEqual(duplicateReceipt, Int64(leftBytes.count), "Lost final receipt replay must be idempotent")
                XCTAssertEqual(try Data(contentsOf: rightTarget), leftBytes)
            }
            let echoLeft = try await left.pending(peerID: rightPeerID)
            let echoRight = try await right.pending(peerID: leftPeerID)
            XCTAssertTrue(echoLeft.isEmpty)
            XCTAssertTrue(echoRight.isEmpty, "Resource publication must not create metadata echo operations")
        }
    }

    func testVerifiedResourceRestartReconcilesProductionPublicationThroughAdapters() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AppDatabase.onDisk(directory: root.appendingPathComponent("a"))
        let left = AutomaticSyncRepository(a)
        let leftPeer = peer(21), rightPeer = peer(22)
        let leftID = AutomaticSyncChannel.peerID(leftPeer), rightID = AutomaticSyncChannel.peerID(rightPeer)
        try await left.configure(peerID: rightID, enabled: true)
        let draft = try await captureArtifact(in: a, sync: left, id: "publication-crash")
        let operations = try await left.pending(peerID: rightID, limit: 256)
        let resourceID = try XCTUnwrap(operations.first { $0.entity == .resource }?.entityID)
        let leftDirectory = root.appendingPathComponent("source-resources")
        let rightDirectory = root.appendingPathComponent("received-resources")
        let sender = AutomaticSyncResourceTransfer(a, directory: leftDirectory)
        let receiverDBPath = root.appendingPathComponent("b")
        do {
            let b = try AppDatabase.onDisk(directory: receiverDBPath)
            let right = AutomaticSyncRepository(b)
            try await right.configure(peerID: leftID, enabled: true)
            try await deliver(operations, to: right, from: leftID)
            let receiver = AutomaticSyncResourceTransfer(b, directory: rightDirectory)
            var offset: Int64 = 0
            while let chunk = try await sender.chunk(resourceID: resourceID, offset: offset, for: rightID) {
                offset = try await receiver.receive(chunk, from: leftID)
            }
            let beforeCrash = try await AnalysisResultRepository(b).latest(meetingId: draft.meetingId, kind: .qa)
            XCTAssertNil(beforeCrash, "Fixture stops after verified bytes commit, before channel completion publishes")
        }
        let reopened = try AppDatabase.onDisk(directory: receiverDBPath)
        let link = QueuedLink()
        let first = AutomaticSyncResourceChannel(
            storage: .repository(database: a, peer: rightPeer, audioDirectory: leftDirectory,
                                 isTrusted: { true }, peerAllowsVoiceprints: { false }),
            send: { link.toRight.append($0) }, onFailure: { link.failures += 1 }
        )
        let second = AutomaticSyncResourceChannel(
            storage: .repository(database: reopened, peer: leftPeer, audioDirectory: rightDirectory,
                                 isTrusted: { true }, peerAllowsVoiceprints: { false }),
            send: { link.toLeft.append($0) }, onFailure: { link.failures += 1 }
        )
        defer { first.stop(); second.stop() }
        try await first.negotiate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if link.failures > 0 { break }
            if !link.toRight.isEmpty { try await second.handle(link.toRight.removeFirst()) }
            if !link.toLeft.isEmpty { try await first.handle(link.toLeft.removeFirst()) }
            let result = try await AnalysisResultRepository(reopened).latest(meetingId: draft.meetingId, kind: .qa)
            if result?.draft == draft { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let recovered = try await AnalysisResultRepository(reopened).latest(meetingId: draft.meetingId, kind: .qa)
        XCTAssertEqual(recovered?.draft, draft,
                       "Verified-but-unpublished resources must be reconciled after restart, not skipped forever")
        let history = try await AnalysisResultRepository(reopened).fetchAll(meetingId: draft.meetingId)
        XCTAssertEqual(history.count, 1, "Restart completion must publish once")
        XCTAssertEqual(link.failures, 0)
    }

    func testSyntheticPlayableAudioThroughProductionAdaptersPreservesSharedContentAfterDeletion() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AppDatabase.onDisk(directory: root.appendingPathComponent("a"))
        let bPath = root.appendingPathComponent("b")
        let b = try AppDatabase.onDisk(directory: bPath)
        let left = AutomaticSyncRepository(a), right = AutomaticSyncRepository(b)
        let leftPeer = peer(11), rightPeer = peer(12)
        let leftID = AutomaticSyncChannel.peerID(leftPeer), rightID = AutomaticSyncChannel.peerID(rightPeer)
        try await left.configure(peerID: rightID, enabled: true)
        try await right.configure(peerID: leftID, enabled: true)
        let leftFiles = AudioFileStore(directory: root.appendingPathComponent("source-audio"))
        let rightFiles = AudioFileStore(directory: root.appendingPathComponent("received-audio"))
        let originalURL = try makeSyntheticAudio(in: leftFiles.directory)
        let originalBytes = try Data(contentsOf: originalURL)
        let digest = try IncrementalSHA256.hashFile(at: originalURL)
        for id in ["shared-audio-one", "shared-audio-two"] {
            try await MeetingRepository(a).insert(Meeting(
                id: id, title: id, startedAt: instant, durationMs: 500,
                audioFileName: originalURL.lastPathComponent, audioSHA256: digest.sha256,
                audioByteCount: digest.byteCount, state: .recorded,
                createdAt: instant, updatedAt: instant, originDeviceId: "synthetic"
            ))
        }
        let outgoing = try await left.pending(peerID: rightID, limit: 256)
        let resources = outgoing.filter { $0.entity == .resource }
        XCTAssertEqual(resources.count, 2)
        XCTAssertEqual(Set(resources.map(\.entityID)).count, 2, "Each meeting owns an independent descriptor")
        try await deliver(outgoing, to: right, from: leftID)
        try await left.acknowledge(peerID: rightID, operationIDs: outgoing.map(\.id))
        let link = QueuedLink()
        var importedMeetings: [String] = []
        let first = AutomaticSyncResourceChannel(
            storage: .repository(database: a, peer: rightPeer, audioDirectory: leftFiles.directory,
                                 isTrusted: { true }, peerAllowsVoiceprints: { false }),
            send: { link.toRight.append($0) }, onFailure: { link.failures += 1 }
        )
        let second = AutomaticSyncResourceChannel(
            storage: .repository(database: b, peer: leftPeer, audioDirectory: rightFiles.directory,
                                 isTrusted: { true }, peerAllowsVoiceprints: { false },
                                 onAudioImported: { imported in
                XCTAssertEqual(imported.peerID, leftID)
                XCTAssertEqual(imported.inputRevision, digest.sha256)
                let operation = try XCTUnwrap(resources.first { $0.id == imported.operationID })
                let descriptor = try JSONDecoder().decode(Wire.Resource.self,
                                                           from: Data(try XCTUnwrap(operation.value).utf8))
                XCTAssertEqual(imported.meetingID, descriptor.meetingID)
                let committedValue = try await MeetingRepository(b).fetch(id: imported.meetingID)
                let committed = try XCTUnwrap(committedValue)
                let fileName = try XCTUnwrap(committed.audioFileName)
                try self.assertDecodableSyntheticAudio(rightFiles.url(forFileName: fileName))
                importedMeetings.append(imported.meetingID)
            }),
            send: { link.toLeft.append($0) }, onFailure: { link.failures += 1 }
        )
        defer { first.stop(); second.stop() }
        try await first.negotiate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if link.failures > 0 { break }
            if !link.toRight.isEmpty { try await second.handle(link.toRight.removeFirst()) }
            if !link.toLeft.isEmpty { try await first.handle(link.toLeft.removeFirst()) }
            let one = try await MeetingRepository(b).fetch(id: "shared-audio-one")
            let two = try await MeetingRepository(b).fetch(id: "shared-audio-two")
            if one?.audioFileName != nil && two?.audioFileName != nil && importedMeetings.count == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(link.failures, 0)
        XCTAssertEqual(importedMeetings.sorted(), ["shared-audio-one", "shared-audio-two"],
                       "Durable audio completion carries exact peer and operation provenance")
        var adoptedURLs: [URL] = []
        for id in ["shared-audio-one", "shared-audio-two"] {
            let meetingValue = try await MeetingRepository(b).fetch(id: id)
            let adopted = try XCTUnwrap(meetingValue)
            let name = try XCTUnwrap(adopted.audioFileName)
            XCTAssertEqual(adopted.audioSHA256, digest.sha256)
            XCTAssertEqual(adopted.audioByteCount, originalBytes.count)
            let playableURL = try rightFiles.url(forFileName: name)
            XCTAssertEqual(try Data(contentsOf: playableURL), originalBytes)
            try assertDecodableSyntheticAudio(playableURL)
            adoptedURLs.append(playableURL)
        }
        // AudioFileStore deletes by filename; adoption gives each descriptor its own managed copy.
        XCTAssertEqual(Set(adoptedURLs.map(\.lastPathComponent)),
                       Set(resources.map { $0.entityID + ".m4a" }),
                       "Same-hash recordings retain independent descriptor-owned playback paths")
        XCTAssertTrue(adoptedURLs.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL.path == rightFiles.directory.standardizedFileURL.path
        }, "Both playable copies must remain inside the receiver's production audio store")
        let receiverTransfer = AutomaticSyncResourceTransfer(b, directory: rightFiles.directory)
        for operation in resources {
            let progress = try await receiverTransfer.progress(resourceID: operation.entityID, from: leftID)
            XCTAssertEqual(progress, Int64(originalBytes.count))
        }
        let beforeDeleteEcho = try await right.pending(peerID: leftID)
        XCTAssertTrue(beforeDeleteEcho.isEmpty, "Adoption cannot emit metadata echo")
        try await MeetingRepository(a).delete(id: "shared-audio-one")
        let deletion = try await left.pending(peerID: rightID)
        try await deliver(deletion, to: right, from: leftID)
        try await right.collectRevokedFiles()
        let removed = try await MeetingRepository(b).fetch(id: "shared-audio-one")
        XCTAssertNil(removed)
        let survivorValue = try await MeetingRepository(b).fetch(id: "shared-audio-two")
        let survivor = try XCTUnwrap(survivorValue)
        let survivingName = try XCTUnwrap(survivor.audioFileName)
        let survivorURL = try rightFiles.url(forFileName: survivingName)
        try assertDecodableSyntheticAudio(survivorURL)
        XCTAssertEqual(try Data(contentsOf: survivorURL), originalBytes)
        var survivingDescriptors = 0
        for operation in resources {
            if let descriptor = try await right.resource(id: operation.entityID) {
                survivingDescriptors += 1
                XCTAssertEqual(descriptor.meetingID, "shared-audio-two")
                XCTAssertEqual(descriptor.sha256, digest.sha256)
            }
        }
        XCTAssertEqual(survivingDescriptors, 1, "Deletion must not invalidate another meeting's global resource reference")
        let restartedDB = try AppDatabase.onDisk(directory: bPath)
        let restarted = AutomaticSyncRepository(restartedDB)
        try await restarted.collectRevokedFiles()
        let restartedMeetingValue = try await MeetingRepository(restartedDB).fetch(id: "shared-audio-two")
        let restartedMeeting = try XCTUnwrap(restartedMeetingValue)
        try assertDecodableSyntheticAudio(rightFiles.url(forFileName: try XCTUnwrap(restartedMeeting.audioFileName)))
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes, "Receiver deletion cannot alter sender-owned audio")
    }

    func testResourceRestartRecoversTruncatedFinalCopyWithoutLosingDurablePrefix() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDB = try AppDatabase.onDisk(directory: root.appendingPathComponent("source"))
        let source = try await configured(sourceDB)
        let draft = try await captureArtifact(in: sourceDB, sync: source, id: "interrupted-copy")
        let operations = try await source.pending(peerID: "peer", limit: 256)
        let id = try XCTUnwrap(operations.first { $0.entity == .resource }?.entityID)
        let descriptorValue = try await source.resource(id: id)
        let descriptor = try XCTUnwrap(descriptorValue)
        let payloadValue = try await source.resourceBytes(id: id, for: "peer")
        let payload = try XCTUnwrap(payloadValue)
        let sourceTransfer = AutomaticSyncResourceTransfer(sourceDB, directory: root.appendingPathComponent("source-bytes"))
        let receiverDBPath = root.appendingPathComponent("receiver")
        let receiverFiles = root.appendingPathComponent("received-bytes")
        let finalPath = receiverFiles.appendingPathComponent(descriptor.sha256)
        let firstValue = try await sourceTransfer.chunk(resourceID: id, offset: 0, for: "peer")
        let first = try XCTUnwrap(firstValue)
        do {
            let receiverDB = try AppDatabase.onDisk(directory: receiverDBPath)
            let receiver = try await configured(receiverDB)
            try await deliver(operations, to: receiver)
            let transfer = AutomaticSyncResourceTransfer(receiverDB, directory: receiverFiles)
            let receipt = try await transfer.receive(first, from: "peer")
            XCTAssertEqual(receipt, Int64(first.bytes.count))
            XCTAssertLessThan(receipt, descriptor.byteCount)
            // Simulate termination during copy-to-final: valid committed staging,
            // but an incomplete hash-named target that never received a SQLite receipt.
            try Data([0x78]).write(to: finalPath)
        }
        let restartedDB = try AppDatabase.onDisk(directory: receiverDBPath)
        let restarted = AutomaticSyncRepository(restartedDB)
        let transfer = AutomaticSyncResourceTransfer(restartedDB, directory: receiverFiles)
        var offset = try await transfer.progress(resourceID: id, from: "peer")
        XCTAssertEqual(offset, Int64(first.bytes.count), "Restart must retain the committed prefix")
        while offset < descriptor.byteCount {
            let nextValue = try await sourceTransfer.chunk(resourceID: id, offset: offset, for: "peer")
            let next = try XCTUnwrap(nextValue)
            let receipt = try await transfer.receive(next, from: "peer")
            XCTAssertGreaterThan(receipt, offset)
            offset = receipt
        }
        XCTAssertEqual(offset, descriptor.byteCount)
        XCTAssertEqual(try Data(contentsOf: finalPath), payload,
                       "An uncommitted truncated copy must not permanently poison restart recovery")
        try await restarted.publishResource(id: id)
        let published = try await AnalysisResultRepository(restartedDB).latest(meetingId: draft.meetingId, kind: .qa)
        XCTAssertEqual(published?.draft, draft)
        let unchangedSource = try await source.resourceBytes(id: id, for: "peer")
        XCTAssertEqual(unchangedSource, payload)
    }

    func testCleanupJournalCannotDeleteAnAcknowledgedActiveResourcePrefix() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AppDatabase.onDisk(directory: root.appendingPathComponent("a"))
        let b = try AppDatabase.onDisk(directory: root.appendingPathComponent("b"))
        let left = try await configured(a), right = try await configured(b)
        _ = try await captureArtifact(in: a, sync: left, id: "cleanup-race")
        let operations = try await left.pending(peerID: "peer", limit: 256)
        let id = try XCTUnwrap(operations.first { $0.entity == .resource }?.entityID)
        try await deliver(operations, to: right)
        let receiveDirectory = root.appendingPathComponent("receiving")
        let sender = AutomaticSyncResourceTransfer(a, directory: root.appendingPathComponent("sending"))
        let receiver = AutomaticSyncResourceTransfer(b, directory: receiveDirectory)
        let firstValue = try await sender.chunk(resourceID: id, offset: 0, for: "peer")
        let first = try XCTUnwrap(firstValue)
        let firstReceipt = try await receiver.receive(first, from: "peer")
        let partials = try FileManager.default.contentsOfDirectory(at: receiveDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".partial-") }
        XCTAssertEqual(partials.count, 1)
        let partial = try XCTUnwrap(partials.first)
        let partialPath = partial.path
        // Seed the persisted state after discard enqueued garbage and a new receive
        // reused that path. This tests deterministic recovery, not scheduler timing.
        try await b.writer.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncFileGarbage(localPath) VALUES(?)",
                           arguments: [partialPath])
        }
        try await right.collectRevokedFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path),
                      "Cleanup must not remove a path referenced by an active durable receive journal")
        let afterCleanup = try await receiver.progress(resourceID: id, from: "peer")
        XCTAssertEqual(afterCleanup, firstReceipt)
        var offset = afterCleanup
        while offset < first.total {
            let nextValue = try await sender.chunk(resourceID: id, offset: offset, for: "peer")
            let next = try XCTUnwrap(nextValue)
            let receipt = try await receiver.receive(next, from: "peer")
            XCTAssertGreaterThan(receipt, offset)
            offset = receipt
        }
        XCTAssertEqual(offset, first.total)
        try await right.collectRevokedFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path),
                       "Completed staging must eventually be collected after ownership ends")
        let payloadValue = try await left.resourceBytes(id: id, for: "peer")
        let payload = try XCTUnwrap(payloadValue)
        let descriptorValue = try await right.resource(id: id)
        let descriptor = try XCTUnwrap(descriptorValue)
        XCTAssertEqual(try Data(contentsOf: receiveDirectory.appendingPathComponent(descriptor.sha256)), payload)
    }

    func testSimulatedVectorConsentDenyPauseRevokeAndPhysicalErasureGate() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AppDatabase.onDisk(directory: root.appendingPathComponent("a"))
        let b = try AppDatabase.onDisk(directory: root.appendingPathComponent("b"))
        let left = try await configured(a), right = try await configured(b)
        let speaker = Speaker(id: "synthetic-speaker", anonymousName: "Fixture", colorIndex: 1, originDeviceId: "a")
        try await SpeakerRepository(a).upsert(speaker)
        // Deliberately simulated property fixture, NOT voiceprint matching/functionality acceptance.
        let embedding = SpeakerEmbedding(id: "synthetic-vector", speakerId: speaker.id,
                                         floats: [0.25, -0.5, 0.75, 1], originDeviceId: "a",
                                         modelIdentifier: "synthetic-model-v1")
        try await SpeakerRepository(a).addEmbedding(embedding)
        let resourceID = try await left.registerVoiceprint(embeddingID: embedding.id, preprocessing: "synthetic-v1")
        let denied = try await left.pending(peerID: "peer", limit: 256)
        XCTAssertTrue(denied.allSatisfy { !$0.biometric })
        await expectFailure(.consentRequired) { _ = try await left.resourceBytes(id: resourceID, for: "peer") }
        try await left.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let operations = try await left.pending(peerID: "peer", limit: 256)
        let biometric = try XCTUnwrap(operations.first { $0.biometric })
        let senderBytes = try await left.resourceBytes(id: resourceID, for: "peer")
        XCTAssertEqual(senderBytes, embedding.vector)
        await expectFailure(.consentRequired) { try await self.deliver([biometric], to: right) }
        let notReceived = try await right.resource(id: resourceID)
        XCTAssertNil(notReceived)
        try await right.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await deliver(operations, to: right)
        let source = root.appendingPathComponent("synthetic-bytes")
        try embedding.vector.write(to: source)
        let installed = try await right.installResource(id: resourceID, from: source,
                                                        directory: root.appendingPathComponent("held"))
        XCTAssertEqual(try Data(contentsOf: installed), embedding.vector)
        try await left.setVoiceprintConsent(peerID: "peer", state: .paused)
        try await right.setVoiceprintConsent(peerID: "peer", state: .paused)
        await expectFailure(.consentRequired) { _ = try await left.resourceBytes(id: resourceID, for: "peer") }
        await expectFailure(.consentRequired) { try await self.deliver([biometric], to: right) }
        await expectFailure(.consentRequired) {
            _ = try await right.installResource(id: resourceID, from: source,
                                                 directory: root.appendingPathComponent("paused-install"))
        }
        let paused = try await right.resource(id: resourceID)
        XCTAssertNotNil(paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path), "Pause retains received bytes")
        try await right.setVoiceprintConsent(peerID: "peer", state: .revoked)
        let revoked = try await right.resource(id: resourceID)
        XCTAssertNil(revoked)
        await expectFailure(.consentRequired) { try await self.deliver([biometric], to: right) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path),
                       "PRODUCT GATE: revoke must erase this peer's locally held biometric bytes, not only SQLite references")
        let restarted = AutomaticSyncRepository(try AppDatabase.onDisk(directory: root.appendingPathComponent("b")))
        try await restarted.collectRevokedFiles()
        try await restarted.collectRevokedFiles()
        let restartedResource = try await restarted.resource(id: resourceID)
        let restartedStatus = try await restarted.status(peerID: "peer")
        XCTAssertNil(restartedResource)
        XCTAssertEqual(restartedStatus.voiceprints, .revoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path),
                       "Startup cleanup is idempotent and must not recreate revoked bytes")
        XCTAssertEqual(try Data(contentsOf: source), embedding.vector,
                       "Revocation cannot erase an independently owned sender fixture")
    }

    func testConcurrentTranscriptPublicationsConvergeAcrossArtifactOrdersAndPreserveLaterEdits() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databases = try (0..<4).map { try AppDatabase.onDisk(directory: root.appendingPathComponent("replica-\($0)")) }
        var repositories: [AutomaticSyncRepository] = []
        for database in databases { repositories.append(try await configured(database)) }
        let left = repositories[0], right = repositories[1]
        let audio = try await seedTranscript(in: databases[0], audioDirectory: root.appendingPathComponent("source-audio"))
        let initial = try await left.pending(peerID: "peer", limit: 512)
        for index in 1..<databases.count {
            try await deliver(initial, to: repositories[index])
            try await adoptSeedAudio(audio, operations: initial, source: databases[0], into: databases[index],
                                     directory: root.appendingPathComponent("audio-\(index)"))
        }
        try await left.acknowledge(peerID: "peer", operationIDs: initial.map(\.id))
        let inputA = try await left.captureProcessingInput(meetingID: "transcript-qa")
        let inputB = try await right.captureProcessingInput(meetingID: "transcript-qa")
        XCTAssertEqual(inputA.transcriptRevision, inputB.transcriptRevision)
        let outputA = transcriptRow("output-a", text: "First independent inference")
        let outputB = transcriptRow("output-b", text: "Second independent inference")
        _ = try await left.publishTranscript(input: inputA, utterances: [outputA],
            publicationID: "publication-a", modelFingerprint: "synthetic-asr", preprocessing: "qa-v1")
        _ = try await right.publishTranscript(input: inputB, utterances: [outputB],
            publicationID: "publication-b", modelFingerprint: "synthetic-asr", preprocessing: "qa-v1")
        let publicationA = try await left.transcriptPublication(publicationID: "publication-a")
        let publicationB = try await right.transcriptPublication(publicationID: "publication-b")
        let idA = try XCTUnwrap(publicationA?.resourceID), idB = try XCTUnwrap(publicationB?.resourceID)
        let payloadA = try await left.resourceBytes(id: idA, for: "peer")
        let payloadB = try await right.resourceBytes(id: idB, for: "peer")
        let bytesA = try XCTUnwrap(payloadA), bytesB = try XCTUnwrap(payloadB)
        let operationsA = try await left.pending(peerID: "peer", limit: 512)
        let operationsB = try await right.pending(peerID: "peer", limit: 512)
        try await deliver(Array(operationsB.reversed()) + operationsB, to: left)
        try await deliver(operationsA + Array(operationsA.reversed()), to: right)
        try await left.acknowledge(peerID: "peer", operationIDs: operationsA.map(\.id))
        try await right.acknowledge(peerID: "peer", operationIDs: operationsB.map(\.id))
        // Two passive replicas see the exact same authors and stamps in opposite orders.
        for index in 2...3 {
            let operations = index == 2 ? operationsA + operationsB : operationsB + operationsA
            try await deliver(operations + Array(operations.reversed()), to: repositories[index])
        }
        let orders = [[(idB, bytesB)], [(idA, bytesA)],
                      [(idA, bytesA), (idB, bytesB)], [(idB, bytesB), (idA, bytesA)]]
        for index in databases.indices {
            let transfer = AutomaticSyncResourceTransfer(databases[index],
                directory: root.appendingPathComponent("bytes-\(index)"))
            for (id, bytes) in orders[index] {
                try await receiveFixtureBytes(bytes, resourceID: id, transfer: transfer)
                _ = try await repositories[index].reconcileVerifiedResources(from: "peer", includeBiometrics: false)
            }
            // Repeat installed bytes and metadata, not just the final comparison.
            for (id, bytes) in orders[index].reversed() {
                try await receiveFixtureBytes(bytes, resourceID: id, transfer: transfer)
            }
            try await deliver(operationsB + operationsA, to: repositories[index])
            _ = try await repositories[index].reconcileVerifiedResources(from: "peer", includeBiometrics: false)
        }
        let visible = try await UtteranceRepository(databases[0]).fetch(meetingId: "transcript-qa")
        XCTAssertEqual(visible.count, 1)
        let selected = try XCTUnwrap(visible.first)
        XCTAssertTrue([outputA.id, outputB.id].contains(selected.id), "An actual candidate, not the input, must win")
        XCTAssertEqual(selected.text, selected.id == outputA.id ? outputA.text : outputB.text)
        let selectedResource = try await left.publishedResource(meetingID: "transcript-qa", kind: .transcript)
        XCTAssertTrue([idA, idB].contains(try XCTUnwrap(selectedResource)))
        for index in 1..<databases.count {
            let rows = try await UtteranceRepository(databases[index]).fetch(meetingId: "transcript-qa")
            let resource = try await repositories[index].publishedResource(meetingID: "transcript-qa", kind: .transcript)
            XCTAssertEqual(rows, visible, "Replica \(index): first-arrival wins is not convergence")
            XCTAssertEqual(resource, selectedResource)
        }
        try await editTranscriptRow(selected.id, in: databases[0], text: "User correction after convergence")
        try await MeetingRepository(databases[0]).rename(id: "transcript-qa", title: "User title", deviceId: "user", now: instant)
        let edits = try await left.pending(peerID: "peer", limit: 512)
        XCTAssertTrue(edits.contains { $0.entity == .utterance && $0.field == "text" })
        for repository in repositories.dropFirst() { try await deliver(edits, to: repository) }
        try await left.acknowledge(peerID: "peer", operationIDs: edits.map(\.id))
        for index in databases.indices {
            try await deliver(operationsA + operationsB + initial, to: repositories[index])
            _ = try await repositories[index].reconcileVerifiedResources(from: "peer", includeBiometrics: false)
            let rows = try await UtteranceRepository(databases[index]).fetch(meetingId: "transcript-qa")
            let meeting = try await MeetingRepository(databases[index]).fetch(id: "transcript-qa")
            let echo = try await repositories[index].pending(peerID: "peer", limit: 512)
            XCTAssertEqual(rows.map(\.text), ["User correction after convergence"])
            XCTAssertEqual(rows.first?.id, selected.id)
            XCTAssertEqual(rows.first?.localeIdentifier, "zh-CN")
            XCTAssertEqual(meeting?.title, "User title")
            XCTAssertTrue(echo.isEmpty, "Artifact adoption/replay must not export synthesized replacement operations")
        }
    }

    func testNewOutputUserEditBeforeTranscriptArtifactSurvivesInstallAndRestartWithoutEcho() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AppDatabase.inMemory(), path = root.appendingPathComponent("receiver")
        let b = try AppDatabase.onDisk(directory: path)
        let left = try await configured(a), right = try await configured(b)
        let audio = try await seedTranscript(in: a, audioDirectory: root.appendingPathComponent("source-audio"))
        let initial = try await left.pending(peerID: "peer", limit: 512)
        try await deliver(initial, to: right)
        try await adoptSeedAudio(audio, operations: initial, source: a, into: b,
                                 directory: root.appendingPathComponent("received-audio"))
        try await left.acknowledge(peerID: "peer", operationIDs: initial.map(\.id))
        let input = try await left.captureProcessingInput(meetingID: "transcript-qa")
        let output = transcriptRow("new-output", text: "Machine text")
        _ = try await left.publishTranscript(input: input, utterances: [output],
            publicationID: "edit-before-artifact", modelFingerprint: "synthetic-asr", preprocessing: "qa-v1")
        let publication = try await left.transcriptPublication(publicationID: "edit-before-artifact")
        let resourceID = try XCTUnwrap(publication?.resourceID)
        let publicationOperations = try await left.pending(peerID: "peer", limit: 512)
        try await left.acknowledge(peerID: "peer", operationIDs: publicationOperations.map(\.id))
        try await editTranscriptRow(output.id, in: a, text: "Human correction before bytes")
        let edits = try await left.pending(peerID: "peer", limit: 512)
        XCTAssertTrue(edits.contains { $0.entityID == output.id && $0.field == "text" })
        try await deliver(Array(edits.reversed()) + edits, to: right)
        try await deliver(publicationOperations, to: right)
        let before = try await UtteranceRepository(b).fetch(meetingId: "transcript-qa")
        XCTAssertFalse(before.contains { $0.id == output.id }, "Scalar edit alone cannot manufacture an incomplete output row")
        let payload = try await left.resourceBytes(id: resourceID, for: "peer")
        let bytes = try XCTUnwrap(payload)
        let directory = root.appendingPathComponent("bytes")
        try await receiveFixtureBytes(bytes, resourceID: resourceID,
            transfer: AutomaticSyncResourceTransfer(b, directory: directory))
        _ = try await right.reconcileVerifiedResources(from: "peer", includeBiometrics: false)
        let reopened = try AppDatabase.onDisk(directory: path), restarted = AutomaticSyncRepository(reopened)
        try await deliver(publicationOperations + edits + initial, to: restarted)
        _ = try await restarted.reconcileVerifiedResources(from: "peer", includeBiometrics: false)
        let rows = try await UtteranceRepository(reopened).fetch(meetingId: "transcript-qa")
        XCTAssertEqual(rows.map(\.id), [output.id])
        XCTAssertEqual(rows.map(\.text), ["Human correction before bytes"])
        XCTAssertEqual(rows.first?.localeIdentifier, "zh-CN")
        XCTAssertEqual(rows.first?.revision, 2)
        let receipt = try await restarted.transcriptPublication(publicationID: "edit-before-artifact")
        let echo = try await restarted.pending(peerID: "peer", limit: 512)
        XCTAssertEqual(receipt?.resourceID, resourceID)
        XCTAssertTrue(echo.isEmpty)
    }

    func testTranscriptKnownSpeakerMixedWithUnknownOrUncoveredAudioStaysUnknown() async throws {
        for scenario in ["unknown-tail", "uncovered-tail", "overlapping-unknown"] {
            let root = fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
            let left = try await configured(a), right = try await configured(b)
            try await left.setVoiceprintConsent(peerID: "peer", state: .allowed)
            try await right.setVoiceprintConsent(peerID: "peer", state: .allowed)
            let audio = try await seedTranscript(in: a, audioDirectory: root.appendingPathComponent("source-audio"),
                                                 identityScenario: scenario)
            let initial = try await left.pending(peerID: "peer", limit: 512)
            try await deliver(initial, to: right)
            try await adoptSeedAudio(audio, operations: initial, source: a, into: b,
                                     directory: root.appendingPathComponent("received-audio"))
            try await left.acknowledge(peerID: "peer", operationIDs: initial.map(\.id))
            let input = try await left.captureProcessingInput(meetingID: "transcript-qa")
            _ = try await left.publishTranscript(input: input,
                utterances: [transcriptRow("merged-output", text: "Merged interval")],
                publicationID: scenario, modelFingerprint: "synthetic-asr", preprocessing: "qa-v1")
            let publication = try await left.transcriptPublication(publicationID: scenario)
            let id = try XCTUnwrap(publication?.resourceID)
            let payload = try await left.resourceBytes(id: id, for: "peer")
            let operations = try await left.pending(peerID: "peer", limit: 512)
            try await deliver(operations, to: right)
            try await receiveFixtureBytes(XCTUnwrap(payload), resourceID: id,
                transfer: AutomaticSyncResourceTransfer(b, directory: root.appendingPathComponent("bytes")))
            _ = try await right.reconcileVerifiedResources(from: "peer", includeBiometrics: true)
            for database in [a, b] {
                let rows = try await UtteranceRepository(database).fetch(meetingId: "transcript-qa")
                XCTAssertEqual(rows.map(\.id), ["merged-output"], scenario)
                XCTAssertNil(rows.first?.speakerId, "\(scenario): Unknown is evidence, not an absent vote for known-A")
            }
            let echo = try await right.pending(peerID: "peer", limit: 512)
            XCTAssertTrue(echo.isEmpty)
        }
    }

    func testTranscriptArtifactOmittingUnknownSourceMappingIsRejectedAtomically() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await configured(a), right = try await configured(b)
        try await left.setVoiceprintConsent(peerID: "peer", state: .allowed)
        try await right.setVoiceprintConsent(peerID: "peer", state: .allowed)
        let audio = try await seedTranscript(in: a, audioDirectory: root.appendingPathComponent("source-audio"),
                                             identityScenario: "unknown-tail")
        let initial = try await left.pending(peerID: "peer", limit: 512)
        try await deliver(initial, to: right)
        try await adoptSeedAudio(audio, operations: initial, source: a, into: b,
                                 directory: root.appendingPathComponent("received-audio"))
        try await left.acknowledge(peerID: "peer", operationIDs: initial.map(\.id))
        let before = try await UtteranceRepository(b).fetch(meetingId: "transcript-qa")
        let input = try await left.captureProcessingInput(meetingID: "transcript-qa")
        _ = try await left.publishTranscript(input: input,
            utterances: [transcriptRow("malicious-output", text: "Attempts to erase uncertainty")],
            publicationID: "omitted-unknown", modelFingerprint: "synthetic-asr", preprocessing: "qa-v1")
        let publication = try await left.transcriptPublication(publicationID: "omitted-unknown")
        let originalID = try XCTUnwrap(publication?.resourceID)
        let originalPayload = try await left.resourceBytes(id: originalID, for: "peer")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(originalPayload)) as? [String: Any])
        let mappings = try XCTUnwrap(object["mappings"] as? [[String: Any]])
        XCTAssertEqual(mappings.count, 2, "The legitimate publisher must represent both overlapping source segments")
        object["mappings"] = mappings.filter { ($0["sourceID"] as? String) != "unknown-source" }
        let forgedBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let forgedID = try await left.registerResource(.init(kind: .transcript, meetingID: "transcript-qa",
            sha256: IncrementalSHA256.hex(SHA256.hash(data: forgedBytes)), byteCount: Int64(forgedBytes.count),
            modelFingerprint: "synthetic-asr", preprocessing: "qa-v1", inputRevision: input.transcriptRevision))
        let operations = try await left.pending(peerID: "peer", limit: 512)
        try await deliver(operations.filter { $0.entity == .resource && $0.entityID == forgedID }, to: right)
        try await receiveFixtureBytes(forgedBytes, resourceID: forgedID,
            transfer: AutomaticSyncResourceTransfer(b, directory: root.appendingPathComponent("bytes")))
        await expectFailure(.invalid) { try await right.publishResource(id: forgedID) }
        let after = try await UtteranceRepository(b).fetch(meetingId: "transcript-qa")
        let receipt = try await right.transcriptPublication(publicationID: "omitted-unknown")
        let published = try await right.publishedResource(meetingID: "transcript-qa", kind: .transcript)
        let echo = try await right.pending(peerID: "peer", limit: 512)
        XCTAssertEqual(after, before, "A hash-valid but incomplete mapping must roll back the entire replacement")
        XCTAssertNil(receipt)
        XCTAssertNil(published)
        XCTAssertTrue(echo.isEmpty)
    }

    func testAudioMetadataFromABytesFromBEnqueuesAndReplaysActualByteSupplier() async throws {
        let root = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let peerA = peer(61), peerB = peer(62), peerC = peer(63)
        let idA = AutomaticSyncChannel.peerID(peerA)
        let idB = AutomaticSyncChannel.peerID(peerB)
        let idC = AutomaticSyncChannel.peerID(peerC)
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let receiverPath = root.appendingPathComponent("receiver")
        let c = try AppDatabase.onDisk(directory: receiverPath)
        let source = AutomaticSyncRepository(a), relay = AutomaticSyncRepository(b), receiver = AutomaticSyncRepository(c)
        try await source.configure(peerID: idB, enabled: true)
        try await relay.configure(peerID: idA, enabled: true)
        try await relay.configure(peerID: idC, enabled: true)
        try await receiver.configure(peerID: idA, enabled: true)
        try await receiver.configure(peerID: idB, enabled: true)
        let sourceDirectory = root.appendingPathComponent("source-audio")
        let relayDirectory = root.appendingPathComponent("relay-audio")
        let receiverDirectory = root.appendingPathComponent("receiver-audio")
        let original = try makeSyntheticAudio(in: sourceDirectory)
        let bytes = try Data(contentsOf: original)
        let digest = try IncrementalSHA256.hashFile(at: original)
        try await MeetingRepository(a).insert(Meeting(
            id: "relayed-audio", title: "Metadata author is not byte supplier", startedAt: instant, durationMs: 500,
            audioFileName: original.lastPathComponent, audioSHA256: digest.sha256, audioByteCount: digest.byteCount,
            state: .recorded, createdAt: instant, updatedAt: instant, originDeviceId: "synthetic"))
        let metadata = try await source.pending(peerID: idB, limit: 512)
        let descriptorOperation = try XCTUnwrap(metadata.first { $0.entity == .resource })
        try await deliver(metadata, to: relay, from: idA)
        try await deliver(metadata, to: receiver, from: idA)
        // B advertises the same immutable operation, not a forged new author/stamp.
        try await deliver([descriptorOperation, descriptorOperation], to: receiver, from: idB)
        try await receiveFixtureBytes(bytes, resourceID: descriptorOperation.entityID,
            transfer: AutomaticSyncResourceTransfer(b, directory: relayDirectory), from: idA)
        try await relay.adoptAudioResource(id: descriptorOperation.entityID)
        let beforeBytes = try await receiver.verifiedAudioImports()
        XCTAssertTrue(beforeBytes.isEmpty, "A's metadata receipt must not enqueue processing")
        let processor = try makeWaitingProcessingModel(database: c, directory: receiverPath,
                                                       audioDirectory: receiverDirectory)
        let link = QueuedLink()
        var callbacks: [AutomaticSyncResourceChannel.AudioImport] = []
        let first = AutomaticSyncResourceChannel(
            storage: .repository(database: b, peer: peerC, audioDirectory: relayDirectory,
                                 isTrusted: { true }, peerAllowsVoiceprints: { false }),
            send: { link.toRight.append($0) }, onFailure: { link.failures += 1 })
        let second = AutomaticSyncResourceChannel(
            storage: .repository(database: c, peer: peerB, audioDirectory: receiverDirectory,
                                 isTrusted: { true }, peerAllowsVoiceprints: { false },
                                 onAudioImported: { imported in
                callbacks.append(imported)
                await processor.enqueueImportedMeeting(meetingID: imported.meetingID,
                    inputRevision: imported.inputRevision,
                    provenance: .init(peerID: imported.peerID, operationID: imported.operationID))
            }),
            send: { link.toLeft.append($0) }, onFailure: { link.failures += 1 })
        defer { first.stop(); second.stop() }
        try await first.negotiate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if link.failures > 0 { break }
            if !link.toRight.isEmpty { try await second.handle(link.toRight.removeFirst()) }
            if !link.toLeft.isEmpty { try await first.handle(link.toLeft.removeFirst()) }
            if !processor.jobs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        first.stop()
        second.stop()
        XCTAssertEqual(link.failures, 0)
        XCTAssertFalse(callbacks.isEmpty, "The real adapter must complete bytes from B despite A's winning descriptor")
        XCTAssertTrue(callbacks.allSatisfy {
            $0.peerID == idB && $0.operationID == descriptorOperation.id
                && $0.meetingID == "relayed-audio" && $0.inputRevision == digest.sha256
        })
        XCTAssertEqual(processor.jobs.count, 1)
        XCTAssertEqual(processor.jobs.first?.automaticImport?.peerID, idB)
        XCTAssertEqual(processor.jobs.first?.automaticImport?.operationID, descriptorOperation.id)
        XCTAssertEqual(processor.jobs.first?.state, .waitingForConfiguration)
        XCTAssertNil(processor.activeJobID)
        let imports = try await receiver.verifiedAudioImports()
        XCTAssertEqual(imports.count, 1)
        let imported = try XCTUnwrap(imports.first)
        XCTAssertEqual(imported.peerID, idB, "Processing authorization follows the durable byte receipt, not metadata A")
        XCTAssertEqual(imported.operationID, descriptorOperation.id)
        XCTAssertEqual(try Data(contentsOf: imported.fileURL), bytes)
        try assertDecodableSyntheticAudio(imported.fileURL)
        let audit = try await receiver.audit(entity: .resource, id: descriptorOperation.entityID)
        XCTAssertEqual(audit.map(\.id), [descriptorOperation.id], "Relay receipt cannot invent a new metadata write")
        let reopened = try AppDatabase.onDisk(directory: receiverPath), restarted = AutomaticSyncRepository(reopened)
        let restoredProcessor = try makeWaitingProcessingModel(database: reopened, directory: receiverPath,
                                                               audioDirectory: receiverDirectory)
        let replay = try await restarted.verifiedAudioImports()
        XCTAssertEqual(replay, imports)
        for item in replay + replay {
            await restoredProcessor.enqueueImportedMeeting(meetingID: item.meetingID, inputRevision: item.audioSHA256,
                provenance: .init(peerID: item.peerID, operationID: item.operationID))
        }
        XCTAssertEqual(restoredProcessor.jobs.count, 1, "Restart and repeated receipt scans deduplicate the persisted queue")
        XCTAssertEqual(restoredProcessor.jobs.first?.id, processor.jobs.first?.id)
        XCTAssertEqual(restoredProcessor.jobs.first?.automaticImport?.peerID, idB)
        XCTAssertEqual(restoredProcessor.jobs.first?.state, .waitingForConfiguration)
        try await restarted.configure(peerID: idB, enabled: false)
        let disabled = try await restarted.verifiedAudioImports()
        XCTAssertTrue(disabled.isEmpty, "Still-enabled metadata author A must not authorize bytes received from disabled B")
        try await restarted.configure(peerID: idB, enabled: true)
        let enabled = try await restarted.verifiedAudioImports()
        XCTAssertEqual(enabled, imports)
        let echoA = try await restarted.pending(peerID: idA, limit: 512)
        let echoB = try await restarted.pending(peerID: idB, limit: 512)
        XCTAssertTrue(echoA.isEmpty)
        XCTAssertFalse(echoB.contains { $0.id == descriptorOperation.id },
                       "B supplied this exact descriptor twice; its durable receipt must suppress echo after restart")
        let originalOperations = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        for operation in echoB {
            XCTAssertEqual(originalOperations[operation.id], operation,
                           "Relaying A's original operation to B is valid; adoption must not synthesize new writes")
        }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    private func makeWaitingProcessingModel(database: AppDatabase, directory: URL,
                                           audioDirectory: URL) throws -> MacProcessingModel {
        struct Configuration: Encodable {
            let version = 1
            let cards: [MacModelCard]
            let selections: [String: String]
            let language = "auto"
        }
        // A card-only selection prevents all inference, downloads and user-model discovery.
        var disabled = try XCTUnwrap(MacModelCard.builtins.first { $0.category == .asr })
        disabled.id = "qa-no-runtime"
        disabled.adapter = .cardOnly
        disabled.localPath = nil
        disabled.bookmark = nil
        let configuration = Configuration(cards: [disabled], selections: ["asr": disabled.id])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("mac-model-catalog.json"))
        let result = MacProcessingModel()
        result.configure(context: MacLibraryContext(database: database, directory: directory,
            audioFiles: AudioFileStore(directory: audioDirectory), deviceID: "qa-receiver"))
        XCTAssertTrue(result.isConfigured)
        XCTAssertFalse(result.canRun)
        return result
    }

    private func seedTranscript(in database: AppDatabase, audioDirectory: URL,
                                identityScenario: String? = nil) async throws -> Data {
        let audioURL = try makeSyntheticAudio(in: audioDirectory, frameCount: 44_100)
        let audio = try Data(contentsOf: audioURL)
        let digest = try IncrementalSHA256.hashFile(at: audioURL)
        try await MeetingRepository(database).insert(Meeting(
            id: "transcript-qa", title: "Original title", startedAt: instant, durationMs: 1_000,
            audioFileName: audioURL.lastPathComponent, audioSHA256: digest.sha256,
            audioByteCount: digest.byteCount, state: .recorded,
            createdAt: instant, updatedAt: instant, originDeviceId: "fixture"))
        guard let identityScenario else {
            try await UtteranceRepository(database).append(transcriptRow("input-row", text: "Original transcript"))
            return audio
        }
        try await SpeakerRepository(database).upsert(Speaker(
            id: "known-a", displayName: "Known A", anonymousName: "Speaker A", originDeviceId: "fixture"))
        var known = transcriptRow("known-source", text: "Known speech")
        known.speakerId = "known-a"
        known.endMs = identityScenario == "overlapping-unknown" ? 1_000 : 500
        try await UtteranceRepository(database).append(known)
        if identityScenario != "uncovered-tail" {
            var unknown = transcriptRow("unknown-source", text: "Unknown speech")
            unknown.startMs = identityScenario == "overlapping-unknown" ? 250 : 500
            unknown.endMs = identityScenario == "overlapping-unknown" ? 750 : 1_000
            try await UtteranceRepository(database).append(unknown)
        }
        return audio
    }

    private func adoptSeedAudio(_ audio: Data, operations: [Wire.Operation], source: AppDatabase,
                                into target: AppDatabase, directory: URL) async throws {
        // Audio identity is deliberately absent from scalar metadata. The receiver
        // needs a verified byte receipt and adoption before accepting an ASR artifact.
        let resourceOperation = try XCTUnwrap(operations.first { $0.entity == .resource })
        let descriptor = try JSONDecoder().decode(Wire.Resource.self,
            from: Data(try XCTUnwrap(resourceOperation.value).utf8))
        XCTAssertEqual(descriptor.kind, .audio)
        XCTAssertEqual(descriptor.meetingID, "transcript-qa")
        XCTAssertEqual(descriptor.sha256, IncrementalSHA256.hex(SHA256.hash(data: audio)))
        XCTAssertEqual(descriptor.byteCount, Int64(audio.count))
        let repository = AutomaticSyncRepository(target)
        try await receiveFixtureBytes(audio, resourceID: resourceOperation.entityID,
                                       transfer: AutomaticSyncResourceTransfer(target, directory: directory))
        try await repository.adoptAudioResource(id: resourceOperation.entityID)
        let sourceMeeting = try await MeetingRepository(source).fetch(id: "transcript-qa")
        let targetMeeting = try await MeetingRepository(target).fetch(id: "transcript-qa")
        XCTAssertEqual(targetMeeting?.audioSHA256, descriptor.sha256)
        XCTAssertEqual(targetMeeting?.audioSHA256, sourceMeeting?.audioSHA256)
        XCTAssertEqual(targetMeeting?.audioByteCount, sourceMeeting?.audioByteCount)
        let sourceInput = try await AutomaticSyncRepository(source).captureProcessingInput(meetingID: "transcript-qa")
        let targetInput = try await repository.captureProcessingInput(meetingID: "transcript-qa")
        XCTAssertEqual(targetInput.audioSHA256, sourceInput.audioSHA256)
        XCTAssertEqual(targetInput.transcriptRevision, sourceInput.transcriptRevision,
                       "Compare persisted source rows and metadata projection before testing publication ordering")
    }

    private func transcriptRow(_ id: String, text: String) -> Utterance {
        Utterance(id: id, meetingId: "transcript-qa", startMs: 0, endMs: 1_000, text: text,
                  createdAt: instant, updatedAt: instant, originDeviceId: "synthetic")
    }

    private func editTranscriptRow(_ id: String, in database: AppDatabase, text: String) async throws {
        // No public text-edit repository method exists; use the persisted model so production triggers capture it.
        try await database.writer.write { db in
            var row = try XCTUnwrap(Utterance.fetchOne(db, key: id))
            row.text = text
            row.localeIdentifier = "zh-CN"
            row.revision += 1
            try row.update(db)
        }
    }

    private func receiveFixtureBytes(_ bytes: Data, resourceID: String,
                                     transfer: AutomaticSyncResourceTransfer,
                                     from peerID: String = "peer") async throws {
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertLessThan(bytes.count, 1_048_576, "Keep the independent fixture bounded")
        for offset in stride(from: 0, to: min(bytes.count, 1_048_576), by: 768) {
            let end = min(offset + 768, bytes.count)
            let chunk = AutomaticSyncResourceWire.Chunk(resourceID: resourceID, offset: Int64(offset),
                total: Int64(bytes.count), bytes: bytes.subdata(in: offset..<end))
            let message = AutomaticSyncResourceWire.Message(kind: .chunk, requestID: "qa-\(offset)", chunk: chunk)
            let decoded = try AutomaticSyncResourceWire.decode(Wire.encode(message))
            let progress = try await transfer.receive(XCTUnwrap(decoded.chunk), from: peerID)
            XCTAssertGreaterThanOrEqual(progress, Int64(end))
            XCTAssertLessThanOrEqual(progress, Int64(bytes.count))
        }
        let progress = try await transfer.progress(resourceID: resourceID, from: peerID)
        XCTAssertEqual(progress, Int64(bytes.count))
    }

    private func makeSyntheticAudio(in directory: URL, frameCount: AVAudioFrameCount = 22_050) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("synthetic-fixture.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        // Matches the existing meeting-copy PCM fixture pattern; no acoustic/voiceprint acceptance.
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.05
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ])
            try file.write(from: buffer)
        }
        return url
    }

    private func assertDecodableSyntheticAudio(_ url: URL, file: StaticString = #filePath,
                                               line: UInt = #line) throws {
        let playable = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(playable.length, 0, file: file, line: line)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: playable.processingFormat, frameCapacity: 1024))
        try playable.read(into: decoded)
        XCTAssertGreaterThan(decoded.frameLength, 0, file: file, line: line)
        XCTAssertEqual(playable.processingFormat.channelCount, 1, file: file, line: line)
    }

    private func captureArtifact(in database: AppDatabase, sync: AutomaticSyncRepository,
                                 id: String) async throws -> AnalysisResultDraft {
        try await MeetingRepository(database).insert(meeting(id, title: id))
        let revision = try await sync.transcriptRevision(meetingID: id)
        let draft = AnalysisResultDraft(id: "\(id)-artifact", meetingId: id, kind: .qa,
                                         payloadJSON: "{\"answer\":\"\(String(repeating: id, count: 300))\"}",
                                         producedByDeviceId: "fixture", producedAt: instant)
        _ = try await AnalysisResultRepository(database).record(
            draft, inputRevision: revision, modelFingerprint: "synthetic-model", preprocessing: "qa-v1"
        )
        return draft
    }

    private func configured(_ database: AppDatabase) async throws -> AutomaticSyncRepository {
        let result = AutomaticSyncRepository(database)
        try await result.configure(peerID: "peer", enabled: true)
        return result
    }

    private func meeting(_ id: String, title: String) -> Meeting {
        Meeting(id: id, title: title, startedAt: instant, durationMs: 1200, state: .recorded,
                createdAt: instant, updatedAt: instant, originDeviceId: "fixture")
    }

    private func peer(_ byte: UInt8) -> MacPairedDevice {
        MacPairedDevice(publicKey: Data(repeating: byte, count: 32), name: "QA-\(byte)", pairedAt: instant)
    }

    private func fixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(".automatic-sync-qa-\(UUID().uuidString)", isDirectory: true)
    }

    private func deliver<S: Sequence>(_ operations: S, to repository: AutomaticSyncRepository,
                                     from peerID: String = "peer") async throws
    where S.Element == Wire.Operation {
        for operation in operations {
            let fragments = try Wire.fragments(for: operation)
            for (index, fragment) in fragments.enumerated() {
                let receipt = try await repository.receive(fragment, from: peerID)
                XCTAssertEqual(receipt, index == fragments.count - 1 ? operation.id : nil)
            }
        }
    }

    private func expectFailure(_ expected: Wire.Failure, file: StaticString = #filePath, line: UInt = #line,
                               operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? Wire.Failure, expected, file: file, line: line)
        }
    }

    private func verifyCommittedAcknowledgement(_ inner: MacPairingMessage,
                                                 repository: AutomaticSyncRepository,
                                                 ids: Set<String>, link: QueuedLink) async throws {
        let message = try Wire.decode(Data(try XCTUnwrap(inner.value).utf8))
        guard message.kind == .ack else { return }
        let id = try XCTUnwrap(message.operationID)
        XCTAssertTrue(ids.contains(id), "A channel must never acknowledge an unsent operation")
        var committedIDs = Set<String>()
        for meetingID in ["left", "right"] {
            let audit = try await repository.audit(entity: .meeting, id: meetingID)
            committedIDs.formUnion(audit.map(\.id))
        }
        XCTAssertTrue(committedIDs.contains(id), "Receipt cannot precede a durable repository commit")
        link.acknowledged.insert(id)
    }

    private final class QueuedLink {
        var toLeft: [MacPairingMessage] = []
        var toRight: [MacPairingMessage] = []
        var acknowledged = Set<String>()
        var failures = 0
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
