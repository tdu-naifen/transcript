import Foundation
import XCTest
@testable import FluidAudio
@testable import TranscriptCore

enum LiveSpeakerFixture {
    static func window(slot: Int = 0, voice: Int = 0, slots: [[Int]?]? = nil) -> CompletedWindowEvidence {
        let frames = slots ?? Array(repeating: [slot], count: 589)
        let mask = MaskWindow(index: 0, offsetSamples: 0, slots: frames)
        let selected = EvidenceAdapter.embeddingFrames(mask, slot: slot)
        let segmentation = SegmentationOutput(
            logProbs: [frames.map { frame in
                guard let frame, let best = EvidenceAdapter.powerset.firstIndex(of: frame) else {
                    return Array(repeating: 0, count: 8)
                }
                return (0..<8).map { $0 == best ? Float(0) : -10 }
            }],
            speakerWeights: [frames.map { frame in (0..<3).map { frame?.contains($0) == true ? Float(1) : 0 } }],
            numChunks: 1, numFrames: 589, numSpeakers: 3, chunkOffsets: [0], frameDuration: 10.0 / 589)
        let row = TimedEmbedding(
            chunkIndex: 0, speakerIndex: slot, startFrame: selected.first ?? 0, endFrame: selected.last ?? 0,
            frameWeights: frames.indices.map { selected.contains($0) ? 1 : 0 },
            startTime: 0, endTime: 10,
            embedding256: (0..<256).map { $0 == voice % 256 ? 1 : 0 },
            rho128: (0..<128).map { $0 == voice % 128 ? 1 : 0 })
        return CompletedWindowEvidence(
            segmentation: segmentation, embeddings: selected.isEmpty ? [] : [row],
            configuration: EvidenceAdapter.configuration())
    }
}

final class LiveSpeakerEvidenceTests: XCTestCase {
    func testProvisionalAnchorOnlyDefersToSoleCAMBoundTrackInCurrentCluster() throws {
        var registry = LiveIdentityRegistry()
        let firstRows = LiveSpeakerFixture.window(voice: 0).rows
        let first = try registry.resolve(rows: firstRows, result: .init(
            runID: UUID(), rowIDs: firstRows.map(\.id), assignments: [0]))
        let secondRows = LiveSpeakerFixture.window(voice: 1).rows
        let secondCohort = registry.cohort(adding: secondRows)
        let second = try registry.resolve(rows: secondRows, result: .init(
            runID: UUID(), rowIDs: secondCohort.map(\.id), assignments: [0, 1]))
        let firstID = try XCTUnwrap(first[0])
        let secondID = try XCTUnwrap(second[0])
        let returning = LiveSpeakerFixture.window().rows
        let cohort = registry.cohort(adding: returning)
        let merged = EvidenceCohortResult(runID: UUID(), rowIDs: cohort.map(\.id),
                                         assignments: Array(repeating: 0, count: cohort.count))
        var noQualifiedTrack = registry
        XCTAssertTrue(try noQualifiedTrack.resolve(rows: returning, result: merged).isEmpty)
        var competingQualifiedTracks = registry
        XCTAssertTrue(try competingQualifiedTracks.resolve(rows: returning, result: merged,
                                                           bound: [firstID, secondID]).isEmpty)
        XCTAssertEqual(try registry.resolve(rows: returning, result: merged, bound: [firstID])[0], firstID)
        XCTAssertEqual(registry.identities.map(\.id), [firstID, secondID], "No rewriting historical evidence IDs.")
    }

    func testFiveThenFortyThenFirstReturnsWithoutSlotInheritanceOrIDRecycling() throws {
        var registry = LiveIdentityRegistry()
        var ids: [String] = []
        for person in 0..<40 {
            let window = LiveSpeakerFixture.window(slot: person % 3, voice: person)
            let cohort = registry.anchors + window.rows
            let labels = Array(0..<person) + [person]
            let result = EvidenceCohortResult(runID: UUID(), rowIDs: cohort.map(\.id), assignments: labels)
            let resolved = try registry.resolve(rows: window.rows, result: result)
            ids.append(try XCTUnwrap(resolved[person % 3]))
            if person == 4 { XCTAssertEqual(Set(ids).count, 5) }
        }
        let returning = LiveSpeakerFixture.window(slot: 2, voice: 0)
        let cohort = registry.anchors + returning.rows
        let result = EvidenceCohortResult(
            runID: UUID(), rowIDs: cohort.map(\.id), assignments: Array(0..<40).map { 100 - $0 } + [100])
        XCTAssertEqual(try registry.resolve(rows: returning.rows, result: result)[2], ids[0])
        XCTAssertEqual(Set(ids).count, 40)
        XCTAssertEqual(registry.identities.count, 40)
        print("LIVE_CAPACITY: 40 synthetic registry identities and returning-first continuity; NOT acoustic accuracy.")
    }

    func testAnchorConflictAndCapacityAbstainWithoutEviction() throws {
        var registry = LiveIdentityRegistry()
        for index in 0..<256 {
            let rows = LiveSpeakerFixture.window(voice: index).rows
            _ = try registry.resolve(rows: rows, result: .init(
                runID: UUID(), rowIDs: (registry.anchors + rows).map(\.id), assignments: Array(0...index)))
        }
        let first = registry.identities[0].id
        let rows = LiveSpeakerFixture.window().rows
        let ids = (registry.anchors + rows).map(\.id)
        XCTAssertTrue(try registry.resolve(rows: rows, result: .init(
            runID: UUID(), rowIDs: ids, assignments: Array(0...256))).isEmpty)
        let conflictRows = LiveSpeakerFixture.window().rows
        let conflictCohort = registry.cohort(adding: conflictRows)
        XCTAssertTrue(try registry.resolve(rows: conflictRows, result: .init(
            runID: UUID(), rowIDs: conflictCohort.map(\.id),
            assignments: [0, 0] + Array(2..<256) + [0, 0])).isEmpty)
        XCTAssertEqual(registry.identities[0].id, first)
        XCTAssertEqual(registry.identities.count, 256)
    }

    func testMaskValidationAndShortTurnDoesNotBecomeIdentityEvidence() throws {
        let short = LiveSpeakerFixture.window(slots: Array(repeating: [0], count: 100) + Array(repeating: [], count: 489))
        XCTAssertTrue(try LiveWindowEvidence(start: 0, evidence: short).rows.isEmpty)
        let valid = LiveSpeakerFixture.window()
        XCTAssertEqual(try LiveWindowEvidence(start: 0, evidence: valid).rows.count, 1)
        XCTAssertThrowsError(try LiveWindowEvidence(start: 1, evidence: valid))
    }

    func testOriginalAHCThresholdKeepsDistantAnchorAndNovelVoiceSeparate() throws {
        var registry = LiveIdentityRegistry()
        let first = LiveSpeakerFixture.window(voice: 0).rows
        let initial = try registry.resolve(rows: first, result: .init(
            runID: UUID(), rowIDs: first.map(\.id), assignments: [0]))
        let different = LiveSpeakerFixture.window(voice: 1).rows
        let cohort = registry.cohort(adding: different)
        let labels = AHCClustering().cluster(
            embeddingFeatures: cohort.map { $0.embedding256.map(Double.init) },
            threshold: EvidenceAdapter.configuration().clusteringThreshold)
        let next = try registry.resolve(rows: different, result: .init(
            runID: UUID(), rowIDs: cohort.map(\.id), assignments: labels))
        XCTAssertNotNil(next[0])
        XCTAssertNotEqual(next[0], initial[0])
        XCTAssertEqual(registry.identities.first?.id, initial[0])
    }

    func testCoverageRejectsSkippedWindowsOverlapAndIdentityDisagreement() throws {
        var assembler = LiveSpeakerAssembler()
        let mask = MaskWindow(index: 0, offsetSamples: 0, slots: Array(repeating: [0], count: 589))
        let first = try assembler.append(start: 0, mask: mask, identities: [0: "first"])
        XCTAssertEqual(first.map(\.identityID), ["first"])
        let conflict = try assembler.append(start: 32_000, mask: mask, identities: [0: "second"])
        XCTAssertTrue(conflict.allSatisfy(\.unknown))
        let missing = try assembler.append(start: 96_000, mask: mask, identities: [0: "first"])
        XCTAssertTrue(missing.allSatisfy(\.unknown))
        let overlap = MaskWindow(index: 0, offsetSamples: 0, slots: Array(repeating: [0, 1], count: 589))
        let simultaneous = try assembler.append(start: 128_000, mask: overlap, identities: [0: "first", 1: "first"])
        XCTAssertTrue(simultaneous.allSatisfy(\.unknown))
        for index in 5..<50 {
            _ = try assembler.append(start: Int64(index * 32_000), mask: mask, identities: [0: "first"])
            XCTAssertLessThanOrEqual(assembler.retainedWindowCount, 5)
        }
    }

    func testRingLatestOnlyAndLongClockWithoutWholeInputHourCap() throws {
        var ring = LiveSpeakerPCM()
        for index in 0..<12 {
            _ = try ring.append(.init(index: index, startFrame: index * 16_000, sampleRate: 16_000,
                                  samples: Array(repeating: Float(index), count: 16_000), isFinal: false))
        }
        let latest = try XCTUnwrap(ring.latestWindow(after: -1))
        XCTAssertEqual(latest.start, 32_000)
        XCTAssertEqual(latest.samples.first, 2)
        XCTAssertEqual(latest.samples.last, 11)
        XCTAssertNil(ring.latestWindow(after: latest.start))
        let hour = 7_200 * 16_000
        XCTAssertTrue(try ring.append(.init(index: 99, startFrame: hour, sampleRate: 16_000,
                                            samples: Array(repeating: 1, count: 192_000), isFinal: false)))
        XCTAssertEqual(ring.count, 192_000)
        XCTAssertEqual(ring.latestWindow(after: latest.start)?.start, Int64(hour + 32_000))
        XCTAssertThrowsError(try ring.append(.init(index: 100, startFrame: 0, sampleRate: 16_000,
                                                   samples: [.nan], isFinal: false)))
    }
}

@MainActor
final class LiveSpeakerNativeTests: XCTestCase {
    func testPinnedCompletedWindowAccessorAndBoundedOriginalRowCohort() async throws {
        guard let path = ProcessInfo.processInfo.environment[DynamicSpeakerModelStore.overrideEnvironmentKey] else {
            throw XCTSkip("Pinned model root required for actual native completed-window smoke.")
        }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reader = try RecordedAudioReader(url: root.appending(path: "Audio/acceptance/librispeech-two-voices-alternating.wav"))
        var pcm: [Float] = []
        while let chunk = await reader.next() { pcm.append(contentsOf: chunk.samples) }
        try await reader.checkFailure()
        let manager = OfflineDiarizerManager(config: EvidenceAdapter.configuration())
        let started = Date()
        manager.initialize(models: try DynamicSpeakerModelStore.loadVerified(directory: URL(filePath: path), cpuOnly: true))
        var registry = LiveIdentityRegistry()
        var assembler = LiveSpeakerAssembler()
        var rowCount = 0
        for start in stride(from: 0, through: pcm.count - 160_000, by: 32_000) {
            let evidence = try await manager.prepareCompletedWindowEvidence(samples: Array(pcm[start..<(start + 160_000)]))
            XCTAssertEqual(evidence.segmentation.numChunks, 1, "No four padded trailing windows.")
            XCTAssertEqual(evidence.segmentation.chunkOffsets, [0])
            let window = try LiveWindowEvidence(start: Int64(start), evidence: evidence)
            rowCount += window.rows.count
            let cohort = registry.cohort(adding: window.rows)
            let clustered = try manager.clusterEvidenceRows(cohort)
            XCTAssertEqual(clustered.rowIDs, cohort.map(\.id))
            let identities = try registry.resolve(rows: window.rows, result: clustered)
            _ = try assembler.append(start: Int64(start), mask: window.mask, identities: identities)
        }
        XCTAssertGreaterThan(rowCount, 0)
        XCTAssertGreaterThanOrEqual(registry.identities.count, 2, "AHC evidence tracks must not collapse to one anchor; canonical person counts are asserted after CAM in the production tests.")
        XCTAssertLessThanOrEqual(assembler.retainedWindowCount, 5)
        do {
            _ = try await manager.prepareCompletedWindowEvidence(samples: Array(repeating: 0, count: 159_999))
            XCTFail("Padding incomplete live input must be rejected.")
        } catch { XCTAssertTrue(error is OfflineDiarizationError) }
        print("LIVE_NATIVE public52s windows=\((pcm.count - 160_000) / 32_000 + 1) rows=\(rowCount) identities=\(registry.identities.count) hostWall=\(Date().timeIntervalSince(started)); not real-time/iPhone/40-voice accuracy.")
    }

    func testActualProductionPipelinePerformsEarlyCAMAndDurablePublication() async throws {
        guard ProcessInfo.processInfo.environment[DynamicSpeakerModelStore.overrideEnvironmentKey] != nil,
              ProcessInfo.processInfo.environment[DiarizationModelStore.campPlusOverrideEnvironmentKey] != nil else {
            throw XCTSkip("Pinned dynamic and existing CAM model roots required.")
        }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reader = try RecordedAudioReader(url: root.appending(path: "Audio/acceptance/librispeech-two-voices-alternating.wav"))
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Public native smoke", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let rows = (0..<51).map { second in
            Utterance(meetingId: meeting.id, startMs: second * 1_000, endMs: (second + 1) * 1_000, text: "Public fixture", originDeviceId: "test")
        }
        try await UtteranceRepository(db).append(rows)
        let slots = LiveTestAdmission()
        let live = LiveDynamicSpeakers(database: db, meetingID: meeting.id, deviceID: "test",
                                      downloader: ASRModelDownloader(), admission: slots.admission, cpuOnly: true)
        let started = Date()
        var chunks = AudioChunkBuffer(frameCount: 32_000)
        let memoryBefore = MemoryFootprint.current()
        var maximumHopSeconds = 0.0
        while let chunk = await reader.next() {
            for windowChunk in chunks.append(chunk.samples) {
                let hopStarted = Date()
                await live.ingest(windowChunk)
                await live.waitForIdle()
                maximumHopSeconds = max(maximumHopSeconds, Date().timeIntervalSince(hopStarted))
            }
        }
        try await reader.checkFailure()
        let result = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        let named = result.compactMap(\.speakerId)
        XCTAssertFalse(named.isEmpty, "Actual completed-window extraction must reach qualified CAM and durable live publication.")
        XCTAssertEqual(Set(named).count, 2, "Both public fixture voices must reach distinct persisted identities.")
        let metrics = await live.metrics()
        print("LIVE_PRODUCTION_NATIVE cpuOnly=true wall=\(Date().timeIntervalSince(started)) maximumPacedHop=\(maximumHopSeconds) processed=\(metrics.processed) identities=\(metrics.identities) persistedPeople=\(Set(named).count) assignedOneSecondRows=\(named.count)/51 footprintBefore=\(memoryBefore ?? -1) footprintAfter=\(MemoryFootprint.current() ?? -1) processLifetimePeak=\(MemoryFootprint.peak() ?? -1). Simulator host, paced fixture ingestion, not a real-time deadline/iPhone/40-voice claim.")
        live.close()
        await live.waitForIdle()
    }

    func testPublicFiveSequentialVoicesThenFirstReturnsThroughProductionPipeline() async throws {
        guard ProcessInfo.processInfo.environment[DynamicSpeakerModelStore.overrideEnvironmentKey] != nil,
              ProcessInfo.processInfo.environment[DiarizationModelStore.campPlusOverrideEnvironmentKey] != nil else {
            throw XCTSkip("Pinned dynamic and CAM model roots required.")
        }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Audio/librispeech-multi")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "flac" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Public sequential smoke", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let slots = LiveTestAdmission()
        let live = LiveDynamicSpeakers(database: db, meetingID: meeting.id, deviceID: "test",
                                      downloader: ASRModelDownloader(), admission: slots.admission, cpuOnly: true)
        var chunks = AudioChunkBuffer(frameCount: 32_000)
        var firstPublication: [Int: Int] = [:]
        let started = Date()
        let memoryBefore = MemoryFootprint.current()
        var maximumHopSeconds = 0.0
        for (turn, source) in [1089, 1188, 121, 237, 260, 1089].enumerated() {
            var samples: [Float] = []
            for file in files where file.lastPathComponent.hasPrefix("\(source)-") {
                let reader = try RecordedAudioReader(url: file)
                while let chunk = await reader.next() { samples.append(contentsOf: chunk.samples) }
                try await reader.checkFailure()
                if samples.count >= 480_000 { break }
            }
            XCTAssertGreaterThanOrEqual(samples.count, 480_000)
            // Check every second of each source turn, not only a favorable middle
            // slice. Unknown is allowed, but a wrong or fragmented person ID is not.
            let rows = (0..<30).map { second in
                Utterance(meetingId: meeting.id, startMs: turn * 30_000 + second * 1_000,
                          endMs: turn * 30_000 + (second + 1) * 1_000, text: "Public turn \(turn)", originDeviceId: "test")
            }
            try await UtteranceRepository(db).append(rows)
            for chunk in chunks.append(Array(samples.prefix(480_000))) {
                let hopStarted = Date()
                await live.ingest(chunk)
                await live.waitForIdle()
                maximumHopSeconds = max(maximumHopSeconds, Date().timeIntervalSince(hopStarted))
                let current = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
                for row in current where row.speakerId != nil {
                    if let turn = row.text.split(separator: " ").last.flatMap({ Int($0) }),
                       firstPublication[turn] == nil {
                        firstPublication[turn] = (chunk.startFrame + chunk.samples.count) / 16 - turn * 30_000
                    }
                }
            }
            let metrics = await live.metrics()
            print("LIVE_PUBLIC_SEQUENTIAL_PROGRESS source=\(source) windows=\(metrics.processed) retainedIdentities=\(metrics.identities)")
        }
        await live.reconcile()
        let rows = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        var identities: [String] = []
        for turn in 0..<6 {
            let ids = Set(rows.filter { $0.text == "Public turn \(turn)" }.compactMap(\.speakerId))
            print("LIVE_PUBLIC_SEQUENTIAL turn=\(turn) persistedIdentityCount=\(ids.count) assignedRows=\(rows.filter { $0.text == "Public turn \(turn)" && $0.speakerId != nil }.count)/30 firstPublicationAtCapturedMs=\(firstPublication[turn] ?? -1)")
            XCTAssertEqual(ids.count, 1, "This public voice needs a stable identity, not inherited slots or fragmentation.")
            if let id = ids.first { identities.append(id) }
        }
        XCTAssertEqual(Set(identities.prefix(5)).count, 5, "A newly arriving public voice must not inherit an old anchor.")
        XCTAssertEqual(identities.first, identities.last, "Returning first voice must retain its canonical identity.")
        live.close()
        await live.waitForIdle()
        print("LIVE_PUBLIC_SEQUENTIAL cpuOnly=true wall=\(Date().timeIntervalSince(started)) maximumPacedHop=\(maximumHopSeconds) assignedRows=\(rows.filter { $0.speakerId != nil }.count)/180 footprintBefore=\(memoryBefore ?? -1) footprintAfter=\(MemoryFootprint.current() ?? -1) processLifetimePeak=\(MemoryFootprint.peak() ?? -1): 5 attributed LibriSpeech voices + returning first, composed 30-second turns; necessary smoke, not representative meeting accuracy or 40-voice acceptance.")
    }
}
