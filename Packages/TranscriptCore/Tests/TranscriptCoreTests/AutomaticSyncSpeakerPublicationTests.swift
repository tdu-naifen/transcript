import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncSpeakerPublicationTests {
    private func fixture(meeting existing: Meeting? = nil) async throws -> (AppDatabase, AutomaticSyncRepository, Meeting) {
        let db = try AppDatabase.inMemory()
        let sync = AutomaticSyncRepository(db)
        try await sync.configure(peerID: "phone", enabled: true, voiceprints: .allowed)
        let meeting = existing ?? Meeting(title: "Synthetic atomic speaker publication", startedAt: Date(), durationMs: 5000,
            audioFileName: "fixture.m4a", audioSHA256: String(repeating: "a", count: 64),
            audioByteCount: 1024, state: .recorded, originDeviceId: "mac")
        try await MeetingRepository(db).insert(meeting)
        return (db, sync, meeting)
    }

    private func analysis(dimension: Int = 192, cleanDuration: Double = 5) -> TranscriptSpeakerAnalysis {
        .init(modelIdentifier: "synthetic-camplus-test", preprocessing: VoiceprintPreprocessing.campPlus,
            voices: [.init(slot: 0, embedding: [1] + Array(repeating: 0, count: dimension - 1),
                           cleanDuration: cleanDuration)],
            timeline: [.init(slot: 0, startFrame: 0, endFrame: 80_000, frameDurationSeconds: 1 / 16_000)])
    }

    @Test func publishesTextIdentityAndArtifactIntentInOneCommitWithoutDuplicateEnrollment() async throws {
        let (db, sync, meeting) = try await fixture()
        let input = try await sync.captureProcessingInput(meetingID: meeting.id)
        let output = Utterance(meetingId: meeting.id, startMs: 0, endMs: 5000,
                               text: "Synthetic transcript", originDeviceId: "mac")
        let revision = try await sync.publishTranscript(input: input, utterances: [output], publicationID: "speaker-result",
            modelFingerprint: "models", preprocessing: "asr16k", speakerAnalysis: analysis())
        let assigned = try #require(try await UtteranceRepository(db).fetch(meetingId: meeting.id).first)
        let speakerID = try #require(assigned.speakerId)
        #expect(assigned.revision == output.revision)
        #expect(try await sync.transcriptRevision(meetingID: meeting.id) == revision)
        let vectors = try await SpeakerRepository(db).embeddings(forSpeaker: speakerID)
        #expect(vectors.count == 1 && vectors.first?.dimension == 192)
        #expect(vectors.first?.preprocessing == VoiceprintPreprocessing.campPlus)
        let all = try await sync.pending(peerID: "phone", limit: 256)
        #expect(all.contains { $0.entity == .speaker && $0.entityID == speakerID })
        #expect(all.contains { $0.entity == .utterance && $0.field == "speakerId" && $0.value == speakerID && $0.biometric })
        let descriptors = try all.filter { $0.entity == .resource }.compactMap {
            try $0.value.map { try JSONDecoder().decode(AutomaticSyncWire.Resource.self, from: Data($0.utf8)) }
        }
        #expect(descriptors.contains { $0.kind == .voiceprint })
        #expect(descriptors.contains { $0.kind == .transcript })
        let withoutConsent = try await sync.pending(peerID: "phone", limit: 256, includeBiometrics: false)
        #expect(!withoutConsent.contains { $0.biometric })
        let repeated = try await sync.publishTranscript(input: input, utterances: [output], publicationID: "speaker-result",
            modelFingerprint: "models", preprocessing: "asr16k", speakerAnalysis: analysis())
        #expect(repeated == revision)
        #expect(try await SpeakerRepository(db).embeddings(forSpeaker: speakerID).count == 1)
        #expect(try await sync.pending(peerID: "phone", limit: 256) == all)
    }

    @Test func invalidSpeakerAnalysisRollsBackTranscriptIdentityAndOutboxTogether() async throws {
        let (db, sync, meeting) = try await fixture()
        let input = try await sync.captureProcessingInput(meetingID: meeting.id)
        let before = try await sync.pending(peerID: "phone", limit: 256)
        let output = Utterance(meetingId: meeting.id, startMs: 0, endMs: 5000,
                               text: "Must roll back", originDeviceId: "mac")
        await #expect(throws: AutomaticSyncWire.Failure.invalid) {
            try await sync.publishTranscript(input: input, utterances: [output], publicationID: "bad-speakers",
                modelFingerprint: "models", preprocessing: "asr16k", speakerAnalysis: analysis(dimension: 2))
        }
        #expect(try await UtteranceRepository(db).fetch(meetingId: meeting.id).isEmpty)
        #expect(try await SpeakerRepository(db).fetchAll().isEmpty)
        #expect(try await sync.pending(peerID: "phone", limit: 256) == before)
        #expect(try await sync.transcriptPublication(publicationID: "bad-speakers") == nil)
    }

    @Test func insufficientVoiceEvidencePublishesTextWithoutInventingIdentity() async throws {
        let (db, sync, meeting) = try await fixture()
        let input = try await sync.captureProcessingInput(meetingID: meeting.id)
        _ = try await sync.publishTranscript(input: input,
            utterances: [.init(meetingId: meeting.id, startMs: 0, endMs: 5000, text: "Keep Unknown", originDeviceId: "mac")],
            publicationID: "short-evidence", modelFingerprint: "models", preprocessing: "asr16k",
            speakerAnalysis: analysis(cleanDuration: 1))
        #expect(try await UtteranceRepository(db).fetch(meetingId: meeting.id).first?.speakerId == nil)
        #expect(try await SpeakerRepository(db).fetchAll().isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func competingVoiceprintPublicationsConverge(reverse: Bool, identitiesBeforeBytes: Bool) async throws {
        let (_, first, meeting) = try await fixture()
        let (_, second, _) = try await fixture(meeting: meeting)
        var artifacts: [(id: String, bytes: Data, operations: [AutomaticSyncWire.Operation], text: String)] = []
        for (index, sync) in [first, second].enumerated() {
            let input = try await sync.captureProcessingInput(meetingID: meeting.id)
            let text = "Candidate \(index)"
            _ = try await sync.publishTranscript(input: input,
                utterances: [.init(meetingId: meeting.id, startMs: 0, endMs: 5000, text: text, originDeviceId: "mac")],
                publicationID: "voice-candidate-\(index)", modelFingerprint: "models", preprocessing: "asr16k",
                speakerAnalysis: analysis())
            let receipt = try #require(try await sync.transcriptPublication(publicationID: "voice-candidate-\(index)"))
            artifacts.append((receipt.resourceID, try #require(try await sync.resourceBytes(id: receipt.resourceID, for: "phone")),
                              try await sync.pending(peerID: "phone", limit: 256), text))
        }
        artifacts.sort { $0.id < $1.id }
        let winner = try #require(artifacts.last)
        let (db, receiver, _) = try await fixture(meeting: meeting)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for candidate in reverse ? Array(artifacts.reversed()) : artifacts {
            let descriptors = candidate.operations.filter { $0.entity == .resource }
            try await receiver.apply(identitiesBeforeBytes ? candidate.operations : descriptors, from: "phone")
            let source = directory.appendingPathComponent(candidate.id)
            try candidate.bytes.write(to: source)
            _ = try await receiver.installResource(id: candidate.id, from: source, directory: directory.appendingPathComponent("installed"))
            try await receiver.publishResource(id: candidate.id)
            if !identitiesBeforeBytes { try await receiver.apply(candidate.operations, from: "phone") }
            try await receiver.publishResource(id: candidate.id)
        }
        #expect(try await UtteranceRepository(db).fetch(meetingId: meeting.id).map(\.text) == [winner.text])
        #expect(try await UtteranceRepository(db).fetch(meetingId: meeting.id).first?.speakerId != nil)
    }
}
