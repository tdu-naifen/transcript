import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncProductionArtifactTests {
    enum Producer: CaseIterable, Sendable { case live, offline }

    private func configured(_ database: AppDatabase) async throws -> AutomaticSyncRepository {
        let repository = AutomaticSyncRepository(database)
        try await repository.configure(peerID: "peer", enabled: true, voiceprints: .allowed)
        return repository
    }

    private func produce(_ producer: Producer, database: AppDatabase, meetingID: String) async throws {
        let vector: [Float] = [1] + Array(repeating: 0, count: 191)
        switch producer {
        case .live:
            let live = LiveSpeakerRepository(database: database, meetingID: meetingID,
                epoch: UUID().uuidString, deviceID: "producer", authorization: .init())
            let identity = LiveSpeakerIdentity(id: UUID().uuidString, ordinal: 0)
            try await live.begin(generation: 0)
            _ = try await live.publish(generation: 0, identities: [identity],
                spans: [.init(startTick: 0, endTick: 2 * LiveSpeakerLimits.ticksPerSecond,
                              identityID: identity.id, unknown: false)],
                voices: [.init(identityID: identity.id, embedding: vector, cleanFrameCount: 32_000)],
                modelIdentifier: "fixture-camp-revision")
            try await live.reconcile(generation: 0)
        case .offline:
            let rows = try await UtteranceRepository(database).fetch(meetingId: meetingID)
            _ = try await SpeakerAnalysisRepository(database).apply(meetingID: meetingID,
                expectedUtterances: rows, slotsByUtterance: [rows[0].id: 0],
                voices: [.init(slot: 0, embedding: vector, cleanDuration: 2)],
                modelIdentifier: "fixture-camp-revision", deviceID: "producer",
                preprocessing: VoiceprintPreprocessing.campPlus)
        }
    }

    @Test(arguments: Producer.allCases)
    func productionEnrollmentTransfersIdentitiesAndActivatesOnlyCompatibleMatcher(_ producer: Producer) async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sync-production-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDB = try AppDatabase.inMemory(), targetDB = try AppDatabase.inMemory()
        let source = try await configured(sourceDB), target = try await configured(targetDB)
        let meeting = Meeting(title: "Production hook fixture", startedAt: Date(),
                              state: .recording, originDeviceId: "producer")
        try await MeetingRepository(sourceDB).insert(meeting)
        try await UtteranceRepository(sourceDB).append(.init(meetingId: meeting.id,
            startMs: 0, endMs: 1_000, text: "Original transcript", originDeviceId: "producer"))
        // These are the production enrollment transactions, not registerVoiceprint.
        try await produce(producer, database: sourceDB, meetingID: meeting.id)
        let speaker = try #require(try await SpeakerRepository(sourceDB).fetchAll().first)
        try await SpeakerRepository(sourceDB).rename(id: speaker.id, displayName: "User chosen name", deviceId: "user")
        let legacy = SpeakerEmbedding(speakerId: speaker.id, floats: [0, 1] + Array(repeating: 0, count: 190),
            originDeviceId: "legacy", modelIdentifier: "fixture-camp-revision")
        try await SpeakerRepository(sourceDB).addEmbedding(legacy)
        let operations = try await source.pending(peerID: "peer", limit: 256)
        let resources = operations.filter { $0.entity == .resource }
        #expect(resources.count == 2)
        let resource = try #require(resources.first)
        let descriptor = try #require(try await source.resource(id: resource.entityID))
        #expect(descriptor.modelFingerprint == "fixture-camp-revision")
        #expect(descriptor.preprocessing == VoiceprintPreprocessing.campPlus && descriptor.dimensions == 192)
        #expect(try await SpeakerRepository(sourceDB).embeddings(forSpeaker: speaker.id)
            .first(where: { $0.id == legacy.id })?.preprocessing == nil)
        let legacyMatcher = VoiceprintMatcher(speakers: SpeakerRepository(sourceDB),
            modelIdentifier: "fixture-camp-revision", includeLegacyEmbeddings: true)
        #expect(try await legacyMatcher.match(embedding: legacy.floats, cleanDuration: 3)
            == .noMatch(candidates: [.init(speakerId: speaker.id, score: 0)]))

        for operation in operations.reversed() {
            for fragment in try AutomaticSyncWire.fragments(for: operation) {
                _ = try await target.receive(fragment, from: "peer", includeBiometrics: true)
            }
        }
        #expect(try await target.resourcesNeedingDownload(from: "peer", limit: 1, includeBiometrics: false).isEmpty)
        #expect(Set(try await target.resourcesNeedingDownload(from: "peer", includeBiometrics: true))
            == Set(resources.map(\.entityID)))
        let importedSpeaker = try #require(try await SpeakerRepository(targetDB).fetchAll().first)
        #expect(importedSpeaker.id.lowercased() == speaker.id.lowercased())
        #expect(importedSpeaker.displayName == "User chosen name")
        #expect(importedSpeaker.anonymousName == speaker.anonymousName && importedSpeaker.colorIndex == speaker.colorIndex)
        let importedRow = try #require(try await UtteranceRepository(targetDB).fetch(meetingId: meeting.id).first)
        #expect(importedRow.speakerId == importedSpeaker.id && importedRow.text == "Original transcript")
        #expect(try await SpeakerRepository(targetDB).speakers(inMeeting: meeting.id).first?.speaker.id == importedSpeaker.id)
        let matcher = VoiceprintMatcher(speakers: SpeakerRepository(targetDB), modelIdentifier: "fixture-camp-revision")
        let query: [Float] = [1] + Array(repeating: 0, count: 191)
        #expect(try await matcher.match(embedding: query, cleanDuration: 3) == .noMatch(candidates: []))
        let sender = AutomaticSyncResourceTransfer(sourceDB, directory: directory.appendingPathComponent("source"))
        let receiver = AutomaticSyncResourceTransfer(targetDB, directory: directory.appendingPathComponent("received"))
        let chunk = try #require(try await sender.chunk(resourceID: resource.entityID, offset: 0, for: "peer"))
        let encoded = try AutomaticSyncWire.encode(AutomaticSyncResourceWire.Message(kind: .chunk, chunk: chunk))
        let decoded = try #require(try AutomaticSyncResourceWire.decode(encoded).chunk)
        #expect(try await receiver.receive(decoded, from: "peer") == 192 * MemoryLayout<Float>.size)
        #expect(Set(try await target.resourcesNeedingDownload(from: "peer"))
            == Set(resources.dropFirst().map(\.entityID)))
        try await target.adoptVoiceprintResource(id: resource.entityID)
        let bank = try await SpeakerRepository(targetDB).embeddings(forSpeaker: importedSpeaker.id)
        #expect(bank.count == 1 && bank.first?.preprocessing == VoiceprintPreprocessing.campPlus)
        #expect(bank.first?.originDeviceId == resource.stamp.deviceID)
        guard case .matched(let matched, _) = try await matcher.match(embedding: query, cleanDuration: 3) else {
            Issue.record("Production-created artifact must invalidate and populate the real matcher")
            return
        }
        #expect(matched == importedSpeaker.id)
        let otherModel = VoiceprintMatcher(speakers: SpeakerRepository(targetDB), modelIdentifier: "other-model")
        let otherPreprocessing = VoiceprintMatcher(speakers: SpeakerRepository(targetDB),
            modelIdentifier: "fixture-camp-revision", preprocessing: "other-preprocessing")
        #expect(try await otherModel.match(embedding: query, cleanDuration: 3) == .noMatch(candidates: []))
        #expect(try await otherPreprocessing.match(embedding: query, cleanDuration: 3) == .noMatch(candidates: []))
        #expect(try await matcher.match(embedding: [1, 0], cleanDuration: 3) == .noMatch(candidates: []))
        #expect(try await target.pending(peerID: "peer", limit: 256).isEmpty)
    }

    @Test(arguments: Producer.allCases)
    func enrollmentAndArtifactOutboxRollBackTogether(_ producer: Producer) async throws {
        let database = try AppDatabase.inMemory()
        let repository = try await configured(database)
        let meeting = Meeting(title: "Rollback", startedAt: Date(), originDeviceId: "source")
        try await MeetingRepository(database).insert(meeting)
        try await UtteranceRepository(database).append(.init(meetingId: meeting.id,
            startMs: 0, endMs: 1_000, text: "Unassigned", originDeviceId: "source"))
        let before = try await repository.pending(peerID: "peer", limit: 256)
        try await database.writer.write {
            try $0.execute(sql: """
                CREATE TRIGGER artifact_failure BEFORE INSERT ON automaticSyncResourcePayload
                BEGIN SELECT RAISE(ABORT, 'injected artifact failure'); END
                """)
        }
        await #expect(throws: (any Error).self) {
            try await produce(producer, database: database, meetingID: meeting.id)
        }
        #expect(try await repository.pending(peerID: "peer", limit: 256) == before)
        #expect(try await SpeakerRepository(database).fetchAll().isEmpty)
        #expect(try await database.reader.read { try SpeakerEmbedding.fetchCount($0) } == 0)
        #expect(try await UtteranceRepository(database).fetch(meetingId: meeting.id).first?.speakerId == nil)
    }
}
