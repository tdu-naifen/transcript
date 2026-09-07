import Foundation
import GRDB
import XCTest
@testable import FluidAudio
@testable import TranscriptCore

private actor GrowingVoiceRuntime: LiveSpeakerInferring {
    enum Mode { case ambiguous, needsMoreAudio, alwaysAmbiguous }
    let mode: Mode
    private(set) var sampleCounts: [Int] = []
    init(mode: Mode = .ambiguous) { self.mode = mode }
    func extract(_ samples: [Float]) -> CompletedWindowEvidence { LiveSpeakerFixture.window() }
    func cluster(_ rows: [CompletedWindowEvidence.Row]) -> EvidenceCohortResult {
        .init(runID: UUID(), rowIDs: rows.map(\.id), assignments: Array(repeating: 0, count: rows.count))
    }
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) -> [Float]? {
        sampleCounts.append(samples.count)
        if mode == .needsMoreAudio, samples.count < 64_000 { return nil }
        // At 2s both enrolled people pass similarity but fail the unchanged margin.
        if mode == .alwaysAmbiguous || samples.count < 64_000 { return [1, 1] + Array(repeating: 0, count: 190) }
        return [1] + Array(repeating: 0, count: 191)
    }
    func close() {}
}

@MainActor
final class LiveSpeakerLatencyTests: XCTestCase {
    func testUnboundTransitionAnchorCannotPermanentlyHideRecognizedReturningSpeaker() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Transition fixture", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        let rows = [0, 12_000].map { Utterance(meetingId: meeting.id, startMs: $0, endMs: $0 + 1_000,
                                              text: "Fixture", originDeviceId: "test") }
        try await UtteranceRepository(database).append(rows)
        let runtime = TransitionVoiceRuntime()
        let live = LiveDynamicSpeakers(
            database: database, meetingID: meeting.id, deviceID: "test", admission: LiveTestAdmission().admission,
            prepareAssets: { .init(dynamic: URL(filePath: "."), camp: URL(filePath: "."), modelIdentifier: "transition-fixture") },
            makeRuntime: { _ in runtime })
        for hop in 0..<11 {
            await live.ingest(.init(index: hop, startFrame: hop * 32_000, sampleRate: 16_000,
                                    samples: Array(repeating: 1, count: 32_000), isFinal: false))
            await live.waitForIdle()
        }
        let final = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        let first = try XCTUnwrap(final.first(where: { $0.id == rows[0].id })?.speakerId)
        XCTAssertEqual(final.first(where: { $0.id == rows[1].id })?.speakerId, first,
                       "A never-bound transition anchor must not veto every future AHC-confirmed return.")
        live.close()
    }

    func testAmbiguousTwoSecondsGrowsAndBindsExistingRowAtNextEvidenceEvent() async throws {
        try await assertGrowingEvidence(mode: .ambiguous)
    }

    private actor TransitionVoiceRuntime: LiveSpeakerInferring {
        private var windows = 0
        func extract(_ samples: [Float]) -> CompletedWindowEvidence { LiveSpeakerFixture.window() }
        func cluster(_ rows: [CompletedWindowEvidence.Row]) -> EvidenceCohortResult {
            windows += 1
            return .init(runID: UUID(), rowIDs: rows.map(\.id),
                         assignments: windows == 2 ? [0, 1] : Array(repeating: 0, count: rows.count))
        }
        func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) -> [Float]? {
            [1] + Array(repeating: 0, count: 191)
        }
        func close() {}
    }

    func testInsufficientCleanAudioIsNotAFatalFailureAndRetriesWithMoreEvidence() async throws {
        try await assertGrowingEvidence(mode: .needsMoreAudio)
    }

    func testPersistentAmbiguityKeepsRollingFiveSecondsBoundedWithoutGuessingOrPolling() async throws {
        try await assertGrowingEvidence(mode: .alwaysAmbiguous)
    }

    private func assertGrowingEvidence(mode: GrowingVoiceRuntime.Mode) async throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Latency fixture", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        let first = Speaker(anonymousName: "First", colorIndex: 0, originDeviceId: "test")
        let second = Speaker(anonymousName: "Second", colorIndex: 1, originDeviceId: "test")
        try await database.writer.write { db in
            for (index, speaker) in [first, second].enumerated() {
                try speaker.insert(db)
                try SpeakerEmbedding(
                    speakerId: speaker.id, floats: (0..<192).map { $0 == index ? 1 : 0 },
                    originDeviceId: "test", modelIdentifier: "latency-fixture",
                    preprocessing: VoiceprintPreprocessing.campPlus
                ).insert(db)
            }
        }
        let row = Utterance(meetingId: meeting.id, startMs: 0, endMs: 1_000, text: "Fixture", originDeviceId: "test")
        try await UtteranceRepository(database).append([row])
        let runtime = GrowingVoiceRuntime(mode: mode)
        let live = LiveDynamicSpeakers(
            database: database, meetingID: meeting.id, deviceID: "test", admission: LiveTestAdmission().admission,
            prepareAssets: { .init(dynamic: URL(filePath: "."), camp: URL(filePath: "."), modelIdentifier: "latency-fixture") },
            makeRuntime: { _ in runtime })
        await live.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await live.waitForIdle()
        let initial = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        XCTAssertNil(initial.first?.speakerId, "A tied 2s voiceprint must not guess either enrolled person.")
        let started = ContinuousClock.now
        await live.ingest(.init(index: 1, startFrame: 160_000, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 32_000), isFinal: false))
        await live.waitForIdle()
        let updated = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        let counts = await runtime.sampleCounts
        XCTAssertEqual(counts, [32_000, 64_000], "A rejected match must retain disjoint verified audio, not retry another 2s forever.")
        XCTAssertEqual(updated.first?.id, row.id)
        if mode == .alwaysAmbiguous {
            for hop in 2..<12 {
                await live.ingest(.init(index: hop, startFrame: 160_000 + (hop - 1) * 32_000, sampleRate: 16_000,
                                        samples: Array(repeating: 1, count: 32_000), isFinal: false))
                await live.waitForIdle()
                let metrics = await live.metrics()
                XCTAssertEqual(metrics.camFrames, 80_000)
            }
            let attempted = await runtime.sampleCounts
            XCTAssertEqual(attempted, [32_000, 64_000] + Array(repeating: 80_000, count: 10))
            await live.reconcile()
            await live.waitForIdle()
            let afterReconcile = await runtime.sampleCounts
            XCTAssertEqual(afterReconcile, attempted, "No new inference without fresh verified audio.")
            let final = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
            XCTAssertNil(final.first?.speakerId)
            let speakers = try await SpeakerRepository(database).fetchAll()
            XCTAssertEqual(speakers.count, 2, "Ambiguity is not evidence of a new person.")
            live.close()
            return
        }
        XCTAssertEqual(updated.first?.speakerId, first.id, "No new ASR event or refresh authorizes this correction.")
        let speakers = try await SpeakerRepository(database).fetchAll()
        XCTAssertEqual(speakers.count, 2)
        print("LIVE_LATENCY fixture_audio_s=12 existing_row_bound=\(updated.first?.speakerId == first.id) event_to_commit_ms=\(LiveSpeakerTiming.milliseconds(from: started, to: .now))")
        live.close()
    }

    func testRealPublicTwoVoicePipelineTimingAndReturningIdentity() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dynamic = environment[DynamicSpeakerModelStore.overrideEnvironmentKey],
              let camp = environment[DiarizationModelStore.campPlusOverrideEnvironmentKey],
              let fixture = environment["TRANSCRIPT_LIVE_LATENCY_FIXTURE"] else {
            throw XCTSkip("Opt-in pinned models and public LibriSpeech alternating fixture required.")
        }
        let reader = try RecordedAudioReader(url: URL(filePath: fixture))
        var samples: [Float] = []
        while let chunk = await reader.next() { samples.append(contentsOf: chunk.samples) }
        try await reader.checkFailure()
        XCTAssertGreaterThan(samples.count, 52 * 16_000)
        let assets = try LiveSpeakerAssets(dynamic: URL(filePath: dynamic), camp: URL(filePath: camp),
                                          modelIdentifier: SpeakerAnalysisEngine.modelIdentifier(at: URL(filePath: camp)))
        let enrollment = try LiveSpeakerNativeRuntime(assets: assets, meetingID: "public-enrollment", cpuOnly: true)
        let short = try await enrollment.voiceprint(Array(samples.prefix(16_000)), ordinal: 0,
                                                   generation: 0, version: -1)
        XCTAssertNil(short, "A normal needs-more-audio result is not an inference failure.")
        let shortLoadedCAM = await enrollment.loadedCAMComputeUnits()
        XCTAssertNil(shortLoadedCAM, "Insufficient samples must not pay a cold CAM load.")
        let database = try AppDatabase.inMemory()
        let people = [
            Speaker(anonymousName: "Fixture 1089", colorIndex: 0, originDeviceId: "test"),
            Speaker(anonymousName: "Fixture 1580", colorIndex: 1, originDeviceId: "test")
        ]
        for (index, start) in [0, 11 * 16_000].enumerated() {
            let result = try await enrollment.voiceprint(Array(samples[start..<start + 80_000]), ordinal: index,
                                                        generation: 0, version: 0)
            let vector = try XCTUnwrap(result)
            let person = people[index]
            try await database.writer.write { db in
                try person.insert(db)
                try SpeakerEmbedding(speakerId: person.id, floats: vector, originDeviceId: "test",
                                     modelIdentifier: assets.modelIdentifier,
                                     preprocessing: VoiceprintPreprocessing.campPlus).insert(db)
            }
        }
        await enrollment.close()
        let meeting = Meeting(title: "Public two-voice timing", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        // Interior ranges avoid the fixture's exact splice boundaries. These rows
        // exist before inference, so later binding must reconcile already shown text.
        let ranges = [(1_000, 2_000, 0), (4_000, 5_000, 0), (12_000, 13_000, 1),
                      (15_000, 16_000, 1), (21_000, 22_000, 0), (24_000, 25_000, 0),
                      (31_000, 32_000, 1), (37_000, 38_000, 0), (40_000, 41_000, 0)]
        let rows = ranges.map { Utterance(meetingId: meeting.id, startMs: $0.0, endMs: $0.1,
                                          text: "Public fixture", originDeviceId: "test") }
        try await UtteranceRepository(database).append(rows)
        let live = LiveDynamicSpeakers(
            database: database, meetingID: meeting.id, deviceID: "test", admission: LiveTestAdmission().admission,
            prepareAssets: { assets },
            makeRuntime: {
                let started = ContinuousClock.now
                let runtime = try LiveSpeakerNativeRuntime(assets: $0, meetingID: meeting.id, cpuOnly: true)
                print("LIVE_REAL stage=runtimeLoading elapsed_ms=\(LiveSpeakerTiming.milliseconds(from: started, to: .now))")
                return TimedPublicVoiceRuntime(runtime: runtime)
            })
        var firstDelivery: [String: Int] = [:]
        let started = ContinuousClock.now
        for offset in stride(from: 0, through: samples.count - 32_000, by: 32_000) {
            await live.ingest(.init(index: offset / 32_000, startFrame: offset, sampleRate: 16_000,
                                    samples: Array(samples[offset..<offset + 32_000]), isFinal: false))
            await live.waitForIdle()
            let persisted = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
            for row in persisted where row.speakerId != nil && firstDelivery[row.id] == nil {
                firstDelivery[row.id] = (offset + 32_000) / 16_000
                print("LIVE_REAL stage=existingRowCommit row_start_ms=\(row.startMs) audio_s=\((offset + 32_000) / 16_000) elapsed_ms=\(LiveSpeakerTiming.milliseconds(from: started, to: .now))")
            }
        }
        let final = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        var matchedPeople: Set<String> = []
        for (row, expected) in zip(rows, ranges) {
            if let assigned = final.first(where: { $0.id == row.id })?.speakerId {
                XCTAssertEqual(assigned, people[expected.2].id, "Confident assignment must match the fixture person.")
                matchedPeople.insert(assigned)
            }
        }
        XCTAssertEqual(matchedPeople.count, 2)
        XCTAssertTrue(final.contains { $0.startMs >= 21_000 && $0.speakerId == people[0].id },
                      "Returning first voice must resolve to the existing enrolled identity.")
        let metrics = await live.metrics()
        XCTAssertEqual(metrics.processed, 22)
        XCTAssertLessThanOrEqual(metrics.camFrames, 160_000)
        live.close()
        print("LIVE_REAL fixture=public_spliced_not_natural_meeting rows_bound=\(firstDelivery.count) people=\(matchedPeople.count) windows=\(metrics.processed)")
    }
}

private actor TimedPublicVoiceRuntime: LiveSpeakerInferring {
    let runtime: LiveSpeakerNativeRuntime
    init(runtime: LiveSpeakerNativeRuntime) { self.runtime = runtime }
    func extract(_ samples: [Float]) async throws -> CompletedWindowEvidence {
        let start = ContinuousClock.now
        let result = try await runtime.extract(samples)
        print("LIVE_REAL stage=windowExtraction elapsed_ms=\(LiveSpeakerTiming.milliseconds(from: start, to: .now))")
        return result
    }
    func cluster(_ rows: [CompletedWindowEvidence.Row]) async throws -> EvidenceCohortResult {
        let start = ContinuousClock.now
        let result = try await runtime.cluster(rows)
        print("LIVE_REAL stage=cohortClustering assignments=\(result.assignments) elapsed_ms=\(LiveSpeakerTiming.milliseconds(from: start, to: .now))")
        return result
    }
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) async throws -> [Float]? {
        let start = ContinuousClock.now
        let result = try await runtime.voiceprint(samples, ordinal: ordinal, generation: generation, version: version)
        print("LIVE_REAL stage=voiceprintInference track=\(ordinal) clean_audio_s=\(Double(samples.count) / 16_000) embedded=\(result != nil) elapsed_ms=\(LiveSpeakerTiming.milliseconds(from: start, to: .now))")
        return result
    }
    func close() async { await runtime.close() }
}
