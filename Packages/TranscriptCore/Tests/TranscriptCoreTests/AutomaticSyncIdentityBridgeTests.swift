import CryptoKit
import Foundation
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncIdentityBridgeTests {
    private func configured(_ database: AppDatabase) async throws -> AutomaticSyncRepository {
        let repository = AutomaticSyncRepository(database)
        try await repository.configure(peerID: "peer", enabled: true, voiceprints: .allowed)
        return repository
    }

    private func exchange(_ source: AutomaticSyncRepository, _ target: AutomaticSyncRepository) async throws {
        while true {
            let operations = try await source.pending(peerID: "peer", limit: 256)
            guard !operations.isEmpty else { return }
            for operation in operations {
                for fragment in try AutomaticSyncWire.fragments(for: operation) {
                    _ = try await target.receive(fragment, from: "peer")
                }
            }
            try await source.acknowledge(peerID: "peer", operationIDs: operations.map(\.id))
        }
    }

    @Test func existingUUIDCaseVariantsKeepBothLocalIdentitiesAndResourceReferencesAfterRestart() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        // This fixture exercises hashing and identity, not audio codec validity.
        let bytes = Data((0..<2_000).map { UInt8($0 % 251) })
        try bytes.write(to: sourceRoot.appendingPathComponent("sealed.m4a"))
        let hash = IncrementalSHA256.hex(SHA256.hash(data: bytes))
        let a = try AppDatabase.inMemory()
        let targetRoot = root.appendingPathComponent("database")
        let b = try AppDatabase.onDisk(directory: targetRoot)
        let left = try await configured(a), right = try await configured(b)
        let meeting = Meeting(title: "original", startedAt: Date(), durationMs: 1000,
                              audioFileName: "sealed.m4a", audioSHA256: hash,
                              audioByteCount: bytes.count, state: .recorded, originDeviceId: "a")
        let speaker = Speaker(displayName: "Same name", anonymousName: "Fox", originDeviceId: "a")
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 10, text: "existing copy",
                                  speakerId: speaker.id, originDeviceId: "a")
        var copiedMeeting = meeting
        copiedMeeting.id = meeting.id.lowercased()
        copiedMeeting.audioFileName = nil
        copiedMeeting.audioSHA256 = nil
        copiedMeeting.audioByteCount = nil
        var copiedSpeaker = speaker
        copiedSpeaker.id = speaker.id.lowercased()
        var copiedUtterance = utterance
        copiedUtterance.id = utterance.id.lowercased()
        copiedUtterance.meetingId = copiedMeeting.id
        copiedUtterance.speakerId = copiedSpeaker.id
        try await MeetingRepository(a).insert(meeting)
        try await SpeakerRepository(a).upsert(speaker)
        try await UtteranceRepository(a).append(utterance)
        try await MeetingRepository(b).insert(copiedMeeting)
        try await SpeakerRepository(b).upsert(copiedSpeaker)
        try await UtteranceRepository(b).append(copiedUtterance)
        try await SpeakerRepository(a).assignDisplayIndex(
            meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: "a")
        try await SpeakerRepository(b).assignDisplayIndex(
            meetingId: copiedMeeting.id, speakerId: copiedSpeaker.id, displayIndex: 0, deviceId: "b")
        let resourceID = try #require(try await left.pending(peerID: "peer").first { $0.entity == .resource }?.entityID)
        let descriptor = try #require(try await left.resource(id: resourceID))
        try await exchange(left, right)
        try await exchange(right, left)

        let receivedRoot = root.appendingPathComponent("received")
        let sender = AutomaticSyncResourceTransfer(a, directory: sourceRoot)
        let receiver = AutomaticSyncResourceTransfer(b, directory: receivedRoot)
        var offset: Int64 = 0
        while let chunk = try await sender.chunk(
            resourceID: resourceID, offset: offset, for: "peer", audioDirectory: sourceRoot
        ) {
            offset = try await receiver.receive(chunk, from: "peer")
        }
        #expect(offset == bytes.count)
        try await right.adoptAudioResource(id: resourceID)
        let reopened = try AppDatabase.onDisk(directory: targetRoot)
        let restarted = AutomaticSyncRepository(reopened)
        #expect(try await restarted.resource(id: resourceID) == descriptor)
        #expect(try AutomaticSyncRepository.resourceID(descriptor) == resourceID)
        let imported = try #require(try await restarted.verifiedAudioImports().first)
        #expect(imported.meetingID == copiedMeeting.id && imported.audioSHA256 == hash)
        #expect(try Data(contentsOf: imported.fileURL) == bytes)
        #expect(try await restarted.transcriptRevision(meetingID: meeting.id)
                == left.transcriptRevision(meetingID: copiedMeeting.id))

        try await MeetingRepository(reopened).rename(id: copiedMeeting.id, title: "return edit", deviceId: "b")
        try await exchange(restarted, left)
        try await exchange(left, restarted)
        #expect(try await MeetingRepository(a).fetchAll().map(\.id) == [meeting.id])
        #expect(try await MeetingRepository(reopened).fetchAll().map(\.id) == [copiedMeeting.id])
        #expect(try await MeetingRepository(a).fetch(id: meeting.id)?.title == "return edit")
        #expect(try await SpeakerRepository(a).fetchAll().map(\.id) == [speaker.id])
        #expect(try await SpeakerRepository(reopened).fetchAll().map(\.id) == [copiedSpeaker.id])
        let leftChild = try #require(try await UtteranceRepository(a).fetch(meetingId: meeting.id).first)
        let rightChildren = try await UtteranceRepository(reopened).fetch(meetingId: copiedMeeting.id)
        let rightChild = try #require(rightChildren.first)
        #expect(rightChildren.count == 1)
        #expect(leftChild.id == utterance.id && leftChild.meetingId == meeting.id && leftChild.speakerId == speaker.id)
        #expect(rightChild.id == copiedUtterance.id && rightChild.meetingId == copiedMeeting.id
                && rightChild.speakerId == copiedSpeaker.id)
        #expect(try await left.pending(peerID: "peer").isEmpty)
        #expect(try await restarted.pending(peerID: "peer").isEmpty)
    }

    @Test func nonUUIDCaseVariantsAndEqualDisplayNamesRemainSeparate() async throws {
        let a = try AppDatabase.inMemory(), b = try AppDatabase.inMemory()
        let left = try await configured(a), right = try await configured(b)
        var upper = Meeting(title: "Same title", startedAt: Date(), originDeviceId: "a")
        upper.id = "User-Key"
        var lower = upper
        lower.id = "user-key"
        try await MeetingRepository(a).insert(upper)
        try await MeetingRepository(b).insert(lower)
        let first = Speaker(displayName: "Same name", anonymousName: "Fox", originDeviceId: "a")
        let second = Speaker(displayName: "Same name", anonymousName: "Fox", originDeviceId: "b")
        try await SpeakerRepository(a).upsert(first)
        try await SpeakerRepository(b).upsert(second)
        try await exchange(left, right)
        try await exchange(right, left)
        for database in [a, b] {
            #expect(Set(try await MeetingRepository(database).fetchAll().map(\.id)) == ["User-Key", "user-key"])
            #expect(Set(try await SpeakerRepository(database).fetchAll().map(\.id)) == [first.id, second.id])
        }
    }
}
