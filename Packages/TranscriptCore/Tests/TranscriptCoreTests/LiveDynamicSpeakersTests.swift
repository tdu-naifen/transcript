import Foundation
import GRDB
import XCTest
@testable import FluidAudio
@testable import TranscriptCore

actor LiveTestAdmission {
    private(set) var held: Set<UUID> = []
    private(set) var peak = 0
    func acquire() -> UUID? {
        guard held.isEmpty else { return nil }
        let id = UUID()
        held.insert(id)
        peak = max(peak, held.count)
        return id
    }
    func release(_ id: UUID) { held.remove(id) }
    var count: Int { held.count }
    nonisolated var admission: LiveSpeakerAdmission {
        .init(acquire: { await self.acquire() }, release: { await self.release($0) })
    }
}

actor LiveTestGate {
    private var opened = false
    private var entered = false
    private var observed: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        if opened { return }
        entered = true
        observed.forEach { $0.resume() }
        observed.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observed.append($0) }
    }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}

actor LiveFixtureRuntime: LiveSpeakerInferring {
    let gate: LiveTestGate?
    init(gate: LiveTestGate? = nil) { self.gate = gate }
    func extract(_ samples: [Float]) async throws -> CompletedWindowEvidence {
        if let gate { await gate.hold() }
        return LiveSpeakerFixture.window(voice: Int(samples.first ?? 0))
    }
    func cluster(_ rows: [CompletedWindowEvidence.Row]) -> EvidenceCohortResult {
        .init(runID: UUID(), rowIDs: rows.map(\.id),
              assignments: rows.map { $0.embedding256.firstIndex(of: 1)! })
    }
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) -> [Float]? {
        (0..<192).map { $0 == Int(samples.first ?? 0) ? 1 : 0 }
    }
    func close() {}
}

@MainActor
final class LiveDynamicSpeakersTests: XCTestCase {
    private func meeting(_ db: AppDatabase) async throws -> Meeting {
        let meeting = Meeting(title: "Live fixture", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        return meeting
    }
    private func pipeline(_ db: AppDatabase, _ meeting: Meeting, slots: LiveTestAdmission, gate: LiveTestGate? = nil) -> LiveDynamicSpeakers {
        LiveDynamicSpeakers(database: db, meetingID: meeting.id, deviceID: "test", admission: slots.admission,
                            prepareAssets: { .init(dynamic: URL(filePath: "."), camp: URL(filePath: "."), modelIdentifier: "CAM-fixture") },
                            makeRuntime: { _ in LiveFixtureRuntime(gate: gate) })
    }

    func testFortySequentialSyntheticVoicesThenFirstReturnsThroughRealPublisher() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = try await meeting(db)
        let slots = LiveTestAdmission()
        let live = pipeline(db, meeting, slots: slots)
        let turns = Array(0..<40) + [0]
        for (turn, voice) in turns.enumerated() {
            try await UtteranceRepository(db).append([
                Utterance(meetingId: meeting.id, startMs: turn * 20_000 + 10_000,
                          endMs: turn * 20_000 + 11_000, text: "Synthetic \(voice)", originDeviceId: "test")
            ])
            for hop in 0..<10 {
                let start = (turn * 10 + hop) * 32_000
                await live.ingest(.init(index: turn * 10 + hop, startFrame: start, sampleRate: 16_000,
                                        samples: Array(repeating: Float(voice), count: 32_000), isFinal: false))
                await live.waitForIdle()
            }
            let metrics = await live.metrics()
            XCTAssertLessThanOrEqual(metrics.pcmFrames, 192_000)
            XCTAssertLessThanOrEqual(metrics.camFrames, 160_000)
            XCTAssertLessThanOrEqual(metrics.windows, 5)
        }
        await live.reconcile()
        let rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.count, 41)
        XCTAssertEqual(Set(rows.prefix(40).compactMap(\.speakerId)).count, 40)
        XCTAssertNotNil(rows.first?.speakerId)
        XCTAssertEqual(rows.first?.speakerId, rows.last?.speakerId)
        let peak = await slots.peak
        XCTAssertEqual(peak, 1)
        live.close()
        print("LIVE_END_TO_END_CAPACITY: 40 synthetic voices + returning-first through actual bounded scheduler, CAM gates, v11 and persisted utterances; no real-voice accuracy claim.")
    }

    func testCloseReturnsBeforePhysicalNativeDrainAndBlocksStalePublicationAndNewInference() async throws {
        let db = try AppDatabase.inMemory()
        let first = try await meeting(db)
        let second = try await meeting(db)
        let slots = LiveTestAdmission()
        let gate = LiveTestGate()
        let old = pipeline(db, first, slots: slots, gate: gate)
        await old.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                               samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await gate.waitForEntry()
        old.close()
        XCTAssertNil(old.authorization.generation)
        let fresh = pipeline(db, second, slots: slots)
        await fresh.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                 samples: Array(repeating: 2, count: 160_000), isFinal: false))
        await fresh.waitForIdle()
        let during = await slots.count
        XCTAssertEqual(during, 1, "Permit must not release while cancelled inference is physically active.")
        await gate.release()
        await old.waitForIdle()
        let after = await slots.count
        let speakers = try await db.reader.read { try Speaker.fetchCount($0) }
        XCTAssertEqual(after, 0)
        XCTAssertEqual(speakers, 0)
        fresh.close()
    }

    func testBackgroundGapAndInputOverloadKeepBoundedStateThenResume() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = try await meeting(db)
        let slots = LiveTestAdmission()
        let live = pipeline(db, meeting, slots: slots)
        await live.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await live.waitForIdle()
        live.setActive(false)
        await live.ingest(.init(index: 1, startFrame: 160_000, sampleRate: 16_000,
                                samples: Array(repeating: 2, count: 32_000), isFinal: false))
        live.setActive(true)
        for hop in 6..<25 {
            await live.ingest(.init(index: hop, startFrame: hop * 32_000, sampleRate: 16_000,
                                    samples: Array(repeating: 1, count: 32_000), isFinal: false))
            await live.waitForIdle()
        }
        let metrics = await live.metrics()
        XCTAssertEqual(metrics.identities, 1)
        XCTAssertGreaterThan(metrics.processed, 5)
        XCTAssertLessThanOrEqual(metrics.pcmFrames, 192_000)
        let gaps = try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM liveSpeakerSpan WHERE unknown = 1") ?? 0 }
        XCTAssertGreaterThan(gaps, 0)
        live.close()
    }

    func testInFlightOverloadRunsOnlyLatestWindowAndPersistsMissingCoverageAsUnknown() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = try await meeting(db)
        let gate = LiveTestGate()
        let live = pipeline(db, meeting, slots: LiveTestAdmission(), gate: gate)
        await live.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await gate.waitForEntry()
        for index in 0..<20 {
            await live.ingest(.init(index: index + 1, startFrame: 160_000 + index * 32_000, sampleRate: 16_000,
                                    samples: Array(repeating: 2, count: 32_000), isFinal: false))
        }
        let held = await live.metrics()
        XCTAssertEqual(held.pcmFrames, 192_000)
        XCTAssertEqual(held.activeWorkers, 1)
        await gate.release()
        while await live.metrics().activeWorkers > 0 { await live.waitForIdle() }
        let finished = await live.metrics()
        XCTAssertEqual(finished.processed, 2, "No FIFO of twenty old inference windows.")
        let gaps = try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM liveSpeakerSpan WHERE unknown = 1") ?? 0 }
        XCTAssertGreaterThan(gaps, 0)
        live.close()
    }

    func testDeletionWhileInferenceIsHeldCannotResurrectMeetingOrGlobalTemplates() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = try await meeting(db)
        let gate = LiveTestGate()
        let slots = LiveTestAdmission()
        let live = pipeline(db, meeting, slots: slots, gate: gate)
        await live.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await gate.waitForEntry()
        try await db.writer.write { _ = try Meeting.deleteOne($0, key: meeting.id) }
        await gate.release()
        await live.waitForIdle()
        let counts = try await db.reader.read { db in
            [try Meeting.fetchCount(db), try Speaker.fetchCount(db), try SpeakerEmbedding.fetchCount(db)]
        }
        let permits = await slots.count
        XCTAssertEqual(counts, [0, 0, 0])
        XCTAssertEqual(permits, 0)
        live.close()
    }

    func testInputDiscontinuityRevokesInFlightEvidenceWithoutCancellingTheRecording() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = try await meeting(db)
        let gate = LiveTestGate()
        let live = pipeline(db, meeting, slots: LiveTestAdmission(), gate: gate)
        await live.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await gate.waitForEntry()
        await live.ingest(.init(index: 2, startFrame: 192_000, sampleRate: 16_000,
                                samples: Array(repeating: 2, count: 32_000), isFinal: false))
        await gate.release()
        await live.waitForIdle()
        let metrics = await live.metrics()
        let count = try await db.reader.read { try Speaker.fetchCount($0) }
        XCTAssertEqual(metrics.processed, 0)
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(live.authorization.generation)
        live.close()
    }
}
