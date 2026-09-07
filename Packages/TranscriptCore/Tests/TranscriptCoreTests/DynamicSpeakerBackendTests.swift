import Foundation
import XCTest
@testable import FluidAudio
@testable import TranscriptCore

@MainActor
final class DynamicSpeakerBackendTests: XCTestCase {
    private var repository: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[DynamicSpeakerModelStore.overrideEnvironmentKey] else {
            throw XCTSkip("Set TRANSCRIPT_DYNAMIC_SPEAKER_MODEL_ROOT to the pinned, hash-verified public models.")
        }
        return URL(filePath: path)
    }

    func testMissingAssetsAreVisibleAndDoNotFallback() async throws {
        let missing = repository.appending(path: ".build/dynamic-speakers-core/nonexistent-models-\(UUID().uuidString)")
        let backend = DynamicSpeakerBackend(modelDirectory: missing)
        do {
            _ = try await backend.analyze(samples: Array(repeating: 0, count: 16_000))
            XCTFail("Missing dynamic models must not fall back to four-slot Sortformer.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing or damaged"))
        }
    }

    func testPrecancelledRunDoesNotPublishAResult() async throws {
        let backend = DynamicSpeakerBackend(modelDirectory: repository)
        let task = Task { () throws -> DynamicSpeakerAnalysis in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await backend.analyze(samples: Array(repeating: 0, count: 16_000))
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPinnedModelLoadsAndSilentAudioHasNoFalseClusterZero() async throws {
        let models = try modelDirectory()
        try DynamicSpeakerModelStore.verify(directory: models)
        let analysis = try await DynamicSpeakerBackend(modelDirectory: models, cpuOnly: true)
            .analyze(samples: Array(repeating: 0, count: 32_001))
        XCTAssertEqual(analysis.audioSampleCount, 32_001)
        XCTAssertTrue(analysis.speakerIndices.isEmpty)
        XCTAssertTrue(analysis.timeline.spans.allSatisfy { $0.speakers.isEmpty })
        XCTAssertEqual(analysis.timeline.spans.last?.endTick, Int64(32_001 * 589))
        print("DYNAMIC_SILENCE modelLoad=\(analysis.modelLoadingSeconds) prepare=\(analysis.preparationSeconds) reconstruction=\(analysis.reconstructionSeconds)")
    }

    func testPublicSpeechFileUsesFullProductionBackendAndCompareStockTiming() async throws {
        let directory = try modelDirectory()
        let audio = repository.appending(path: "Audio/acceptance/librispeech-two-voices-alternating.wav")
        guard FileManager.default.fileExists(atPath: audio.path) else { throw XCTSkip("Public LibriSpeech acceptance fixture not installed.") }
        let workspace = repository.appending(path: ".build/dynamic-speakers-core/test-audio")
        let analysis = try await DynamicSpeakerBackend(modelDirectory: directory, workspace: workspace, cpuOnly: true)
            .analyze(audioURL: audio)
        XCTAssertGreaterThan(analysis.audioSampleCount, 16_000)
        XCTAssertFalse(analysis.speakerIndices.isEmpty, "Real speech must traverse embedding/PLDA/VBx, not just silence inference.")
        XCTAssertEqual(analysis.audioSHA256, try IncrementalSHA256.hashFile(at: audio).sha256)
        XCTAssertEqual(analysis.timeline.spans.last?.endTick, Int64(analysis.audioSampleCount * 589))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty)
        for index in analysis.speakerIndices {
            if let clean = try? analysis.cleanEvidence(speakerIndex: index, minimumDuration: VoiceprintMatchPolicy().minimumCleanDuration) {
                XCTAssertLessThanOrEqual(clean.cleanFrameCount, 80_000)
            }
        }

        let reader = try RecordedAudioReader(url: audio)
        var samples: [Float] = []
        while let chunk = await reader.next() { samples.append(contentsOf: chunk.samples) }
        try await reader.checkFailure()
        let manager = OfflineDiarizerManager(config: EvidenceAdapter.configuration())
        manager.initialize(models: try DynamicSpeakerModelStore.loadVerified(directory: directory, cpuOnly: true))
        let baselineStart = Date()
        let prepared = try await manager.prepare(audio: samples)
        let prepareSeconds = Date().timeIntervalSince(baselineStart)
        let stockStart = Date()
        let stock = try manager.cluster(prepared)
        let stockSeconds = Date().timeIntervalSince(stockStart)
        let sameRunStart = Date()
        let sameRun = try manager.clusterWithEvidence(prepared)
        let sameRunSeconds = Date().timeIntervalSince(sameRunStart)
        XCTAssertFalse(sameRun.assignments.isEmpty)
        XCTAssertTrue(sameRun.assignments.allSatisfy { $0.embedding256.count == 256 })
        let reconstructionStart = Date()
        let reconstructed = try EvidenceAdapter.reconstruct(sameRun)
        let reconstructionSeconds = Date().timeIntervalSince(reconstructionStart)
        XCTAssertEqual(reconstructed.spans, analysis.timeline.spans)
        print("""
        DYNAMIC_PUBLIC_SPEECH seconds=\(Double(samples.count) / 16_000) sha256=\(analysis.audioSHA256 ?? "")
        modelLoad=\(analysis.modelLoadingSeconds) audioDecode=\(analysis.audioLoadingSeconds) prepare=\(analysis.preparationSeconds) clustering=\(analysis.clusteringSeconds) reconstruction=\(analysis.reconstructionSeconds)
        sameInputBaselinePrepare=\(prepareSeconds) stockClusterAndReconstruction=\(stockSeconds) evidenceCluster=\(sameRunSeconds) evidenceReconstruction=\(reconstructionSeconds)
        embeddingRows=\(sameRun.assignments.count) stockTracks=\(Set(stock.segments.map(\.speakerId)).count) evidenceTracks=\(analysis.speakerIndices.count)
        This is two-public-voice smoke and host timing, NOT forty-person acoustic accuracy, DER or live latency.
        """)
    }

    func testUnknownAndOverlapNeverEnrollAndFifthIdentitySurvivesProjection() throws {
        let scale: Int64 = 16_000
        let timeline = EvidenceTimeline(ticksPerSecond: scale, spans: [
            EvidenceSpan(startTick: 0, endTick: 2 * scale, speakers: ["S5"], unknownSpeakerCount: 1, reasons: [.unsupportedSlot]),
            EvidenceSpan(startTick: 2 * scale, endTick: 4 * scale, speakers: ["S5", "S6"], unknownSpeakerCount: 0, reasons: []),
            EvidenceSpan(startTick: 4 * scale, endTick: 8 * scale, speakers: ["S5"], unknownSpeakerCount: 0, reasons: [])
        ])
        let analysis = DynamicSpeakerAnalysis(
            runID: UUID(), timeline: timeline, audioSampleCount: 128_000, audioSHA256: nil,
            modelRevision: DynamicSpeakerModelStore.revision, modelLoadingSeconds: 0, audioLoadingSeconds: 0,
            preparationSeconds: 0, clusteringSeconds: 0, reconstructionSeconds: 0)
        XCTAssertEqual(analysis.speakerIndices, [4, 5])
        XCTAssertNil(analysis.speakerIndex(startMs: 0, endMs: 2_000))
        XCTAssertNil(analysis.speakerIndex(startMs: 2_000, endMs: 4_000))
        XCTAssertEqual(analysis.speakerIndex(startMs: 4_000, endMs: 8_000), 4)
        XCTAssertNil(analysis.speakerIndex(startMs: 4_000, endMs: 8_001))
        let clean = try analysis.cleanEvidence(speakerIndex: 4, minimumDuration: 3)
        XCTAssertEqual(clean.ranges, [64_000..<128_000])
        XCTAssertTrue(analysis.segments.contains { $0.speakerIndex == -1 })
        XCTAssertThrowsError(try analysis.cleanEvidence(speakerIndex: 5, minimumDuration: 3))
    }

    func testExplicitUnknownClearsOnlyUnrevisedAnonymousAndKeepsGlobalBank() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Unknown evidence", startedAt: Date(), state: .recorded, originDeviceId: "qa")
        try await MeetingRepository(database).insert(meeting)
        let speakers = SpeakerRepository(database)
        let anonymous = try await speakers.createAnonymousSpeaker(deviceId: "qa")
        let named = try await speakers.createAnonymousSpeaker(deviceId: "qa")
        try await speakers.rename(id: named.id, displayName: "Manual name", deviceId: "qa")
        try await speakers.addEmbedding(.init(speakerId: anonymous.id, floats: [1, 0], originDeviceId: "qa", modelIdentifier: "test-cam"))
        let rows = [
            Utterance(meetingId: meeting.id, startMs: 0, endMs: 1000, text: "automatic", speakerId: anonymous.id, originDeviceId: "qa"),
            Utterance(meetingId: meeting.id, startMs: 1000, endMs: 2000, text: "named", speakerId: named.id, originDeviceId: "qa"),
            Utterance(meetingId: meeting.id, startMs: 2000, endMs: 3000, text: "possibly manual", speakerId: anonymous.id, revision: 2, originDeviceId: "qa")
        ]
        try await UtteranceRepository(database).append(rows)
        let expected = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        let beforeBank = try await speakers.embeddings(forSpeaker: anonymous.id)
        try await SpeakerAnalysisRepository(database).apply(
            meetingID: meeting.id, expectedUtterances: expected, slotsByUtterance: [:],
            unknownUtteranceIDs: Set(rows.map(\.id)), voices: [], modelIdentifier: "test-cam", deviceID: "qa")
        let after = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        XCTAssertNil(after[0].speakerId)
        XCTAssertEqual(after[0].revision, 2)
        XCTAssertEqual(after.map(\.text), rows.map(\.text))
        XCTAssertEqual(after[1], expected[1])
        XCTAssertEqual(after[2], expected[2])
        let afterBank = try await speakers.embeddings(forSpeaker: anonymous.id)
        XCTAssertEqual(afterBank, beforeBank)
        let allSpeakers = try await speakers.fetchAll()
        XCTAssertEqual(allSpeakers.count, 2)
    }

    func testUnknownPublicationRejectsStaleAndCancelledWorkWithoutWrites() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Stale", startedAt: Date(), state: .recorded, originDeviceId: "qa")
        try await MeetingRepository(database).insert(meeting)
        let speaker = try await SpeakerRepository(database).createAnonymousSpeaker(deviceId: "qa")
        let row = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1000, text: "preserve", speakerId: speaker.id, originDeviceId: "qa")
        let utterances = UtteranceRepository(database)
        try await utterances.append([row])
        try await utterances.assignSpeaker(utteranceId: row.id, speakerId: speaker.id, deviceId: "manual")
        let expected = try await utterances.fetch(meetingId: meeting.id)
        do {
            try await SpeakerAnalysisRepository(database).apply(
                meetingID: meeting.id, expectedUtterances: [row], slotsByUtterance: [:],
                unknownUtteranceIDs: [row.id], voices: [], modelIdentifier: "test-cam", deviceID: "qa")
            XCTFail("Stale publication")
        } catch VoiceprintBindingError.staleExpectation {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SpeakerAnalysisRepository(database).apply(
                meetingID: meeting.id, expectedUtterances: expected, slotsByUtterance: [:],
                unknownUtteranceIDs: [row.id], voices: [], modelIdentifier: "test-cam", deviceID: "qa")
        }
        do { _ = try await task.value; XCTFail("Cancelled publication") }
        catch is CancellationError {}
        let after = try await utterances.fetch(meetingId: meeting.id)
        XCTAssertEqual(after, expected)
    }

    func testPreviouslyAutomaticRevisionTwoCanBecomeExplicitUnknown() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Automatic provenance", startedAt: Date(), state: .recorded, originDeviceId: "qa")
        try await MeetingRepository(database).insert(meeting)
        let utterances = UtteranceRepository(database)
        try await utterances.append([Utterance(meetingId: meeting.id, startMs: 0, endMs: 2000,
                                               text: "Preserve text", originDeviceId: "qa")])
        let initial = try await utterances.fetch(meetingId: meeting.id)
        let repository = SpeakerAnalysisRepository(database)
        let identities = try await repository.apply(
            meetingID: meeting.id, expectedUtterances: initial, slotsByUtterance: [initial[0].id: 0],
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 2)],
            modelIdentifier: "test-cam", deviceID: "qa")
        let known = try await utterances.fetch(meetingId: meeting.id)
        XCTAssertEqual(known[0].revision, 2)
        XCTAssertEqual(known[0].speakerId, identities[0]?.id)
        try await repository.apply(
            meetingID: meeting.id, expectedUtterances: known, slotsByUtterance: [:],
            unknownUtteranceIDs: [known[0].id], voices: [], modelIdentifier: "test-cam", deviceID: "qa")
        let unknown = try await utterances.fetch(meetingId: meeting.id)
        XCTAssertNil(unknown[0].speakerId)
        XCTAssertEqual(unknown[0].revision, 3)
        XCTAssertEqual(unknown[0].text, known[0].text)
        let speakers = try await SpeakerRepository(database).fetchAll()
        XCTAssertEqual(speakers.count, 1)
        let templates = try await SpeakerRepository(database).embeddings(forSpeaker: try XCTUnwrap(identities[0]?.id))
        XCTAssertEqual(templates.count, 1)
    }
}
