import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncProcessingInputTests {
    enum Mutation: String, CaseIterable, Sendable {
        case assignment, text, timing, link, displayIndex, name, audio, purge, deletion
    }

    private func fixture(_ database: AppDatabase) async throws -> (Meeting, Utterance, Speaker) {
        let meeting = Meeting(title: "processing", startedAt: Date(), durationMs: 1_000,
            audioSHA256: String(repeating: "a", count: 64), state: .recorded, originDeviceId: "source")
        let speaker = Speaker(displayName: "Original", anonymousName: "Fox", originDeviceId: "source")
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1_000,
            text: "original\0text", originDeviceId: "source")
        try await MeetingRepository(database).insert(meeting)
        try await SpeakerRepository(database).upsert(speaker)
        try await SpeakerRepository(database).assignDisplayIndex(meetingId: meeting.id,
            speakerId: speaker.id, displayIndex: 0, deviceId: "source")
        try await UtteranceRepository(database).append(utterance)
        return (meeting, utterance, speaker)
    }

    @Test(arguments: Mutation.allCases)
    func localTokenRejectsNewerInputsWithoutWritingOutput(_ mutation: Mutation) async throws {
        let database = try AppDatabase.inMemory()
        let repository = AutomaticSyncRepository(database)
        try await repository.configure(peerID: "peer", enabled: true, voiceprints: .allowed)
        let (meeting, original, speaker) = try await fixture(database)
        let token = try await repository.captureProcessingInput(meetingID: meeting.id)
        #expect(try JSONDecoder().decode(AutomaticSyncRepository.ProcessingInput.self,
            from: JSONEncoder().encode(token)) == token)
        switch mutation {
        case .assignment:
            // Remote assignment projection need not bump the content revision.
            try await database.writer.write {
                try $0.execute(sql: "UPDATE utterance SET speakerId=? WHERE id=?",
                               arguments: [speaker.id, original.id])
            }
            #expect(try await repository.transcriptRevision(meetingID: meeting.id) == token.transcriptRevision)
        case .text:
            try await database.writer.write {
                try $0.execute(sql: "UPDATE utterance SET text=? WHERE id=?", arguments: ["user edit", original.id])
            }
        case .timing:
            try await database.writer.write {
                try $0.execute(sql: "UPDATE utterance SET startMs=1 WHERE id=?", arguments: [original.id])
            }
        case .link:
            try await database.writer.write {
                try $0.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId=?", arguments: [meeting.id])
            }
        case .displayIndex:
            try await SpeakerRepository(database).remapDisplayIndexes(meetingId: meeting.id,
                mapping: [speaker.id: 3], deviceId: "user")
        case .name:
            try await SpeakerRepository(database).rename(id: speaker.id, displayName: "User name", deviceId: "user")
        case .audio:
            try await database.writer.write {
                try $0.execute(sql: "UPDATE meeting SET audioSHA256=? WHERE id=?",
                               arguments: [String(repeating: "b", count: 64), meeting.id])
            }
        case .purge:
            _ = try await MeetingRepository(database).markAudioVerifiedOnMac(id: meeting.id, deviceId: "user")
            try await MeetingRepository(database).markLocalAudioPurged(id: meeting.id, deviceId: "user")
        case .deletion:
            try await MeetingRepository(database).delete(id: meeting.id)
        }
        let beforeRows = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        let beforeOutbox = try await repository.pending(peerID: "peer", limit: 256)
        let replacement = Utterance(meetingId: meeting.id, startMs: 0, endMs: 900,
            text: "worker output", originDeviceId: "mac")
        await #expect(throws: AutomaticSyncWire.Failure.staleRevision) {
            try await repository.publishTranscript(input: token, utterances: [replacement],
                publicationID: "stale-job", modelFingerprint: "model", preprocessing: "16k")
        }
        #expect(try await UtteranceRepository(database).fetch(meetingId: meeting.id) == beforeRows)
        #expect(try await repository.pending(peerID: "peer", limit: 256) == beforeOutbox)
        #expect(try await repository.transcriptPublication(publicationID: "stale-job") == nil)
    }

    @Test func committedTokenPublicationRecoversAfterReopenWithoutOverwritingNewerEdit() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-processing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("database.sqlite").path
        let token: AutomaticSyncRepository.ProcessingInput
        let replacement: Utterance
        let output: String
        do {
            let database = try AppDatabase(DatabaseQueue(path: path))
            let repository = AutomaticSyncRepository(database)
            let (meeting, _, _) = try await fixture(database)
            token = try await repository.captureProcessingInput(meetingID: meeting.id)
            replacement = Utterance(meetingId: meeting.id, startMs: 1, endMs: 900,
                text: "committed output", originDeviceId: "mac")
            output = try await repository.publishTranscript(input: token, utterances: [replacement],
                publicationID: "stable-job", modelFingerprint: "model", preprocessing: "16k")
        }
        let database = try AppDatabase(DatabaseQueue(path: path))
        let repository = AutomaticSyncRepository(database)
        try await repository.configure(peerID: "peer", enabled: true)
        let receipt = try #require(try await repository.transcriptPublication(publicationID: "stable-job"))
        #expect(receipt.outputRevision == output && receipt.publicationID == "stable-job")
        #expect(try await repository.resource(id: receipt.resourceID)?.inputRevision == token.transcriptRevision)
        try await database.writer.write {
            try $0.execute(sql: "UPDATE utterance SET text=? WHERE id=?",
                           arguments: ["later user edit", replacement.id])
        }
        let before = try await repository.pending(peerID: "peer", limit: 256)
        #expect(try await repository.publishTranscript(input: token, utterances: [replacement],
            publicationID: "stable-job", modelFingerprint: "model", preprocessing: "16k") == output)
        #expect(try await UtteranceRepository(database).fetch(meetingId: token.meetingID).first?.text == "later user edit")
        #expect(try await repository.pending(peerID: "peer", limit: 256) == before)
        #expect(try await repository.transcriptPublication(publicationID: "stable-job") == receipt)
        await #expect(throws: AutomaticSyncWire.Failure.equivocation) {
            try await repository.publishTranscript(input: token, utterances: [replacement],
                publicationID: "stable-job", modelFingerprint: "changed-model", preprocessing: "16k")
        }
    }
}
