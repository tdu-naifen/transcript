import XCTest
import CoreML
import Darwin
@testable import FluidAudio
@testable import TranscriptCore

final class DynamicSpeakerEvidenceTests: XCTestCase {
    func vector(_ identity: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 256)
        result[identity] = 1
        return result
    }

    func capture(_ slots: [[Int]?], samples: Int = 32_000) -> MaskCapture {
        MaskCapture(sampleCount: samples, framesPerWindow: slots.count,
                    windows: [MaskWindow(index: 0, offsetSamples: 0, slots: slots)])
    }

    func assignment(_ window: MaskWindow, slot: Int, id: Int) throws -> ChunkEmbedding {
        let mask = EvidenceAdapter.embeddingFrames(window, slot: slot)
        let first = try XCTUnwrap(mask.first), last = try XCTUnwrap(mask.last)
        let offset = Double(window.offsetSamples) / 16_000
        let duration = 10.0 / Double(window.slots.count)
        let embedding = TimedEmbedding(chunkIndex: window.index, speakerIndex: slot,
            startFrame: first, endFrame: last,
            frameWeights: window.slots.indices.map { mask.contains($0) ? 1 : 0 },
            startTime: offset + Double(first) * duration, endTime: offset + Double(last + 1) * duration,
            embedding256: vector(id), rho128: [])
        return try XCTUnwrap(OfflineDiarizerManager.buildPublicChunkEmbeddings(
            timedEmbeddings: [embedding], assignments: [id], logger: AppLogger(category: "PrototypeFixture")).first)
    }

    func reconstruct(_ capture: MaskCapture, _ assignments: [ChunkEmbedding]) throws -> EvidenceTimeline {
        try DynamicSpeakerTestHarness.reconstruct(capture, assignments: assignments)
    }

    func testFiveAndFortyActualAHCIdentityTracksAndRepeatedSpeakers() throws {
        var receipts: [[String: Any]] = []
        for identities in [5, 40, 64] {
            // Two complete passes through orthogonal 256-dimensional speaker groups.
            let features = (0..<(identities * 2)).map { vector($0 % identities).map(Double.init) }
            let labels = AHCClustering().cluster(embeddingFeatures: features,
                                                threshold: OfflineDiarizerConfig.default.clusteringThreshold)
            XCTAssertEqual(Set(labels).count, identities)
            for speaker in 0..<identities { XCTAssertEqual(labels[speaker], labels[speaker + identities]) }

            let sampleCount = identities * 2 * 4 * 16_000
            let frames = 10
            var windows: [MaskWindow] = []
            var embeddings: [ChunkEmbedding] = []
            for offset in stride(from: 0, to: sampleCount, by: 32_000) {
                var slotIDs: [Int] = []
                let slots: [[Int]?] = (0..<frames).map { frame in
                    let sample = offset + frame * 16_000
                    guard sample < sampleCount else { return [] }
                    let period = sample / (4 * 16_000)
                    let id = labels[period]
                    if !slotIDs.contains(id) { slotIDs.append(id) }
                    return [slotIDs.firstIndex(of: id)!]
                }
                let window = MaskWindow(index: windows.count, offsetSamples: offset, slots: slots)
                XCTAssertLessThanOrEqual(slotIDs.count, 3)
                windows.append(window)
                for (slot, id) in slotIDs.enumerated()
                    where !EvidenceAdapter.embeddingFrames(window, slot: slot).isEmpty {
                    embeddings.append(try assignment(window, slot: slot, id: id))
                }
            }
            let timeline = try reconstruct(MaskCapture(sampleCount: sampleCount, framesPerWindow: frames,
                                                       windows: windows), embeddings)
            let observed = Set(timeline.spans.flatMap(\.speakers))
            XCTAssertEqual(observed.count, identities)
            var namedTicks: Int64 = 0
            var correctTicks: Int64 = 0
            for span in timeline.spans where !span.speakers.isEmpty {
                let period = Int(span.startTick / timeline.ticksPerSecond) / 4
                XCTAssertEqual(span.speakers, ["S\(labels[period] + 1)"])
                XCTAssertLessThanOrEqual(span.endTick, Int64((period + 1) * 4) * timeline.ticksPerSecond)
                namedTicks += span.endTick - span.startTick
                if span.speakers == ["S\(labels[period] + 1)"] { correctTicks += span.endTick - span.startTick }
            }
            for identity in 0..<identities {
                let id = "S\(labels[identity] + 1)"
                XCTAssertTrue(timeline.spans.contains { $0.speakers.contains(id) &&
                    $0.startTick >= Int64(identities * 4) * timeline.ticksPerSecond })
            }
            print("STRUCTURAL RECEIPT: \(identities) AHC groups, \(features.count) 256D inputs, "
                  + "\(observed.count) real reconstructed identity tracks, repeated pass joined.")
            receipts.append([
                "syntheticIdentityCount": identities, "AHCInputCount": features.count,
                "AHCInputDimensions": 256, "AHCThreshold": 0.6, "outputIdentityTracks": observed.count,
                "repeatedGroupsJoined": true, "namedTicks": namedTicks, "correctNamedTicks": correctTicks,
                "namedFixturePrecision": Double(correctTicks) / Double(namedTicks),
                "namedFixtureCoverage": Double(namedTicks) / Double(Int64(sampleCount * frames)),
                "seconds": Double(sampleCount) / 16_000, "realVoiceAccuracyMeasured": false
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
        print("DYNAMIC_STRUCTURAL_RECEIPT \(String(decoding: data, as: UTF8.self))")
    }

    func testZeroVoteStockBugReproducedAndAdapterAbstains() throws {
        let masks: [[Int]?] = Array(repeating: [0], count: 5)
        let captured = capture(masks)
        let segmentation = SegmentationOutput(
            logProbs: [], speakerWeights: [Array(repeating: [1, 0, 0], count: 5)],
            numChunks: 1, numFrames: 5, numSpeakers: 3, chunkOffsets: [0], frameDuration: 2)
        let stock = OfflineReconstruction(config: .default).buildSegments(
            segmentation: segmentation, hardClusters: [[-2, -2, -2]],
            centroids: [vector(0).map(Double.init)])
        XCTAssertFalse(stock.isEmpty)
        XCTAssertTrue(stock.allSatisfy { $0.speakerId == "S1" })
        let corrected = try reconstruct(captured, [])
        XCTAssertTrue(corrected.spans.allSatisfy { $0.speakers.isEmpty && $0.unknownSpeakerCount == 1 })
        XCTAssertEqual(corrected.spans[0].reasons, [.unsupportedSlot])
    }

    func testMixedValidUnsupportedRetainsKnownPlusUnknownOverlap() throws {
        // First frame has overlap. Slot 0 also has enough clean evidence; slot 1 has none.
        let captured = capture([[0, 1], [0], [0], [], []])
        let timeline = try reconstruct(captured, [assignment(captured.windows[0], slot: 0, id: 0)])
        XCTAssertEqual(timeline.spans[0].speakers, ["S1"])
        XCTAssertEqual(timeline.spans[0].unknownSpeakerCount, 1)
        XCTAssertEqual(timeline.spans[0].reasons, [.unsupportedSlot])
    }

    func testSupportedOverlapPreservedNotExclusive() throws {
        let captured = capture([[0, 1], [0], [1], [], []])
        let timeline = try reconstruct(captured, [assignment(captured.windows[0], slot: 0, id: 0),
                                                 assignment(captured.windows[0], slot: 1, id: 1)])
        XCTAssertEqual(timeline.spans[0].speakers, ["S1", "S2"])
        XCTAssertEqual(timeline.spans[0].unknownSpeakerCount, 0)
    }

    func testConflictingWindowsAreUnknownNotFabricatedOverlap() throws {
        let a = MaskWindow(index: 0, offsetSamples: 0, slots: Array(repeating: [0], count: 5))
        let b = MaskWindow(index: 1, offsetSamples: 32_000, slots: Array(repeating: [0], count: 5))
        let captured = MaskCapture(sampleCount: 64_000, framesPerWindow: 5, windows: [a, b])
        let timeline = try reconstruct(captured, [assignment(a, slot: 0, id: 0), assignment(b, slot: 0, id: 1)])
        XCTAssertEqual(timeline.spans[0].speakers, ["S1"])
        XCTAssertEqual(timeline.spans.last?.speakers, [])
        XCTAssertEqual(timeline.spans.last?.unknownSpeakerCount, 1)
        XCTAssertTrue(timeline.spans.last!.reasons.contains(.conflictingIdentity))
    }

    func testUnsupportedWindowCannotBorrowAnotherWindowsIdentity() throws {
        let a = MaskWindow(index: 0, offsetSamples: 0, slots: Array(repeating: [0], count: 5))
        let b = MaskWindow(index: 1, offsetSamples: 32_000, slots: Array(repeating: [0], count: 5))
        let timeline = try reconstruct(MaskCapture(sampleCount: 64_000, framesPerWindow: 5, windows: [a, b]),
                                       [assignment(a, slot: 0, id: 0)])
        XCTAssertEqual(timeline.spans.last?.speakers, [])
        XCTAssertTrue(timeline.spans.last!.reasons.contains(.unsupportedSlot))
    }

    func testExact589FrameBoundariesAndTailClipping() throws {
        let a = MaskWindow(index: 0, offsetSamples: 0, slots: Array(repeating: [0], count: 589))
        let b = MaskWindow(index: 1, offsetSamples: 32_000, slots: Array(repeating: [1], count: 589))
        let captured = MaskCapture(sampleCount: 32_001, framesPerWindow: 589, windows: [a, b])
        let timeline = try reconstruct(captured, [assignment(a, slot: 0, id: 0)])
        XCTAssertEqual(timeline.ticksPerSecond, 589 * 16_000)
        XCTAssertEqual(timeline.spans[0].endTick, 32_000 * 589)
        XCTAssertEqual(timeline.spans.last?.startTick, 32_000 * 589)
        XCTAssertEqual(timeline.spans.last?.endTick, 32_001 * 589)
        XCTAssertEqual(timeline.spans.last?.speakers, [])
        // SDK rounds 2 / (10/589) to frame 118 (~2.003396s). We never shift the 2s boundary.
        XCTAssertNotEqual(32_000 * 589, 118 * 160_000)
    }

    func testNoBridgingSilenceOrUnknownGaps() throws {
        let captured = capture([[0], [], nil, [0], [0], [0], [], [], [], []])
        let timeline = try reconstruct(captured, [assignment(captured.windows[0], slot: 0, id: 0)])
        XCTAssertEqual(timeline.spans.count, 2) // audio ends at 2s, before the ambiguous third frame
        XCTAssertEqual(timeline.spans[0].speakers, ["S1"])
        XCTAssertEqual(timeline.spans[1].speakers, [])
        XCTAssertEqual(timeline.spans[1].unknownSpeakerCount, 0)
    }

    func testUnknownGapNeverMergedIntoNamedNeighbors() throws {
        var masks: [[Int]?] = Array(repeating: [0], count: 20)
        masks[1] = nil
        let captured = capture(masks)
        let timeline = try reconstruct(captured, [assignment(captured.windows[0], slot: 0, id: 0)])
        XCTAssertEqual(timeline.spans.count, 3)
        XCTAssertEqual(timeline.spans[0].speakers, ["S1"])
        XCTAssertEqual(timeline.spans[1].speakers, [])
        XCTAssertEqual(timeline.spans[1].unknownSpeakerCount, 1)
        XCTAssertEqual(timeline.spans[1].reasons, [.ambiguousLogits])
        XCTAssertEqual(timeline.spans[2].speakers, ["S1"])
        XCTAssertEqual(timeline.spans[1].startTick, 160_000)
        XCTAssertEqual(timeline.spans[1].endTick, 320_000)
    }

    func testCollapsedOverlapIdentityAbstainsRatherThanTrustingOneLabel() throws {
        let captured = capture([[0, 1], [0], [1], [], []])
        let timeline = try reconstruct(captured, [assignment(captured.windows[0], slot: 0, id: 0),
                                                 assignment(captured.windows[0], slot: 1, id: 0)])
        XCTAssertEqual(timeline.spans[0].speakers, [])
        XCTAssertEqual(timeline.spans[0].unknownSpeakerCount, 2)
        XCTAssertEqual(timeline.spans[0].reasons, [.conflictingIdentity])
    }

    func testFullBoundSixHundredSecondsAbstainsWithExactCoverage() throws {
        let windows = (0..<300).map {
            MaskWindow(index: $0, offsetSamples: $0 * 32_000, slots: Array(repeating: [0], count: 589))
        }
        let start = Date()
        let timeline = try reconstruct(MaskCapture(sampleCount: 600 * 16_000,
                                                   framesPerWindow: 589, windows: windows), [])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(timeline.spans.count, 1)
        XCTAssertEqual(timeline.spans[0].speakers, [])
        XCTAssertEqual(timeline.spans[0].unknownSpeakerCount, 1)
        XCTAssertEqual(timeline.spans[0].endTick, Int64(600 * 16_000 * 589))
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let receipt: [String: Any] = [
            "kind": "synthetic mask-only bounded reconstruction, not model throughput",
            "audioTimelineSeconds": 600, "windows": 300, "framesPerWindow": 589,
            "inputLocalFrames": 300 * 589, "adapterSeconds": elapsed,
            "processHighWaterRSSBytes": usage.ru_maxrss,
            "rssScope": "Whole XCTest process high-water; not isolated adapter allocation",
            "namedIdentitiesWithoutEvidence": 0, "outputUnknownCoverage": 1
        ]
        print("DYNAMIC_STRESS_RECEIPT \(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self))")
    }

    func testPowersetDecodeIncludingOverlapTieNaNAndStrides() throws {
        let array = try MLMultiArray(shape: [1, 10, 8], dataType: .double)
        for i in 0..<array.count { array[i] = -20 }
        for frame in 0..<8 { array[[0, NSNumber(value: frame), NSNumber(value: frame)]] = 3 }
        for cls in 0..<8 { array[[0, 8, NSNumber(value: cls)]] = 0 }
        array[[0, 9, 1]] = NSNumber(value: Double.nan)
        let decoded = try EvidenceAdapter.decode(array, offsets: [0], firstIndex: 0)
        for frame in 0..<8 { XCTAssertEqual(decoded[0].slots[frame], EvidenceAdapter.powerset[frame]) }
        XCTAssertNil(decoded[0].slots[8])
        XCTAssertNil(decoded[0].slots[9])
        let storage = UnsafeMutablePointer<Double>.allocate(capacity: 160)
        defer { storage.deallocate() }
        storage.initialize(repeating: -20, count: 160)
        for frame in 0..<10 { storage[frame * 16 + 2] = 3 }
        let strided = try MLMultiArray(dataPointer: storage, shape: [1, 10, 8], dataType: .double,
                                      strides: [160, 16, 2], deallocator: nil)
        let decodedStrides = try EvidenceAdapter.decode(strided, offsets: [0], firstIndex: 0)
        XCTAssertTrue(decodedStrides[0].slots.allSatisfy { $0 == [0] })
        XCTAssertThrowsError(try EvidenceAdapter.decode(array, offsets: [0, 32_000], firstIndex: 0))
    }

    func testMalformedGeometryFailsClosedAndFortyOneIsNotACap() throws {
        XCTAssertThrowsError(try reconstruct(MaskCapture(sampleCount: 32_000, framesPerWindow: 5, windows: []), []))
        XCTAssertThrowsError(try reconstruct(MaskCapture(sampleCount: EvidenceAdapter.maxSamples + 1,
                                                         framesPerWindow: 5, windows: []), []))
        let invalid = MaskWindow(index: 0, offsetSamples: 1, slots: Array(repeating: [0], count: 5))
        XCTAssertThrowsError(try reconstruct(MaskCapture(sampleCount: 32_000, framesPerWindow: 5,
                                                         windows: [invalid]), []))
        let windows = (0..<41).map {
            MaskWindow(index: $0, offsetSamples: $0 * 32_000, slots: Array(repeating: [0], count: 5))
        }
        let assignments = try windows.enumerated().map { try assignment($0.element, slot: 0, id: $0.offset) }
        XCTAssertNoThrow(try reconstruct(MaskCapture(sampleCount: 41 * 32_000, framesPerWindow: 5,
                                                     windows: windows), assignments))
    }

    func testBadEmbeddingsDuplicateSlotsAndWrongEndpointsAbstain() throws {
        let captured = capture(Array(repeating: [0], count: 5))
        let good = try assignment(captured.windows[0], slot: 0, id: 0)
        let variants = [
            ChunkEmbedding(speakerId: "S1", chunkIndex: 0, speakerIndex: 0,
                           startTimeSeconds: 0, endTimeSeconds: 10, embedding256: [Float](repeating: 1, count: 192)),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 0, speakerIndex: 0,
                           startTimeSeconds: 0, endTimeSeconds: 10, embedding256: [Float](repeating: 0, count: 256)),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 0, speakerIndex: 0,
                           startTimeSeconds: 0, endTimeSeconds: 10, embedding256: [Float](repeating: .nan, count: 256)),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 0, speakerIndex: 0,
                           startTimeSeconds: 1, endTimeSeconds: 10, embedding256: vector(0)),
            ChunkEmbedding(speakerId: "S0", chunkIndex: 0, speakerIndex: 0,
                           startTimeSeconds: 0, endTimeSeconds: 10, embedding256: vector(0))
        ]
        for variant in variants {
            XCTAssertTrue(try reconstruct(captured, [variant]).spans.allSatisfy { $0.speakers.isEmpty })
        }
        XCTAssertTrue(try reconstruct(captured, [good, good]).spans.allSatisfy { $0.speakers.isEmpty })
    }

    func testPublicEndpointsCannotProveSameRunMaskIdentity() throws {
        // Different interior slot masks, identical per-slot start/end times. Replay may look
        // aligned but lacks the actual extraction masks, so neither replay is trusted.
        let a = capture([[0], [0], [1], [0], [1], [1], [0], [1], [0], [1]])
        let b = capture([[0], [0], [1], [1], [0], [0], [1], [1], [0], [1]])
        let assignments = try [assignment(a.windows[0], slot: 0, id: 0),
                               assignment(a.windows[0], slot: 1, id: 1)]
        for slot in 0..<2 {
            let alternate = try assignment(b.windows[0], slot: slot, id: slot)
            XCTAssertEqual(assignments[slot].startTimeSeconds, alternate.startTimeSeconds)
            XCTAssertEqual(assignments[slot].endTimeSeconds, alternate.endTimeSeconds)
        }
        let result = DiarizationResult(segments: [], chunkEmbeddings: assignments)
        for replay in [a, b] {
            let timeline = try EvidenceAdapter.reconstructPublicReplay(replay, result: result)
            XCTAssertTrue(timeline.spans.allSatisfy {
                $0.speakers.isEmpty && $0.reasons.contains(.unverifiedReplay)
            })
        }
    }

    func testSDKPolicyUnchangedAndEnrollmentSpaceRejected() {
        let config = EvidenceAdapter.configuration()
        XCTAssertEqual(config.clusteringThreshold, 0.6)
        XCTAssertEqual(config.minSegmentDuration, 1)
        XCTAssertEqual(config.speechOnsetThreshold, 0.5)
        XCTAssertEqual(config.speechOffsetThreshold, 0.5)
        XCTAssertTrue(config.embeddingExcludeOverlap)
        XCTAssertFalse(config.zeroVoteReembed.enabled)
        XCTAssertFalse(config.exclusiveSegments)
        XCTAssertTrue(config.exposeChunkEmbeddings)
        XCTAssertNil(config.clustering.maxSpeakers)
        XCTAssertNil(config.clustering.numSpeakers)
    }

    func testSameRunDiagnosticBridgeUsesActualSDKExposureAndRejectsMismatchedPayload() throws {
        let weights: [[Float]] = Array(repeating: [1, 0, 0], count: 5)
        let logs: [[Float]] = Array(repeating: [-10, 0, -10, -10, -10, -10, -10], count: 5)
        let segmentation = SegmentationOutput(logProbs: [logs], speakerWeights: [weights],
            numChunks: 1, numFrames: 5, numSpeakers: 3, chunkOffsets: [0], frameDuration: 2)
        let embedding = TimedEmbedding(chunkIndex: 0, speakerIndex: 0, startFrame: 0, endFrame: 4,
            frameWeights: Array(repeating: 1, count: 5), startTime: 0, endTime: 10,
            embedding256: vector(0), rho128: [])
        let prepared = PreparedDiarization(audioSource: ArrayAudioSampleSource(samples: Array(repeating: 0, count: 32_000)),
            segmentation: segmentation, timedEmbeddings: [embedding], audioLoadingSeconds: 0,
            segmentationSeconds: 0, embeddingExtractionSeconds: 0, prepareWallSeconds: 0)
        let assignments = OfflineDiarizerManager.buildPublicChunkEmbeddings(
            timedEmbeddings: [embedding], assignments: [0], logger: AppLogger(category: "PrototypeFixture"))
        let result = DiarizationResult(segments: [], chunkEmbeddings: assignments)
        let timeline = try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000)
        XCTAssertEqual(timeline.spans[0].speakers, ["S1"])
        XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(
            prepared, result: DiarizationResult(segments: [], chunkEmbeddings: []), sampleCount: 32_000))
        XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 31_999))
    }

    private func maskValidationFixture(
        slots: [[Int]] = [[0], [0, 1], [], [0], [], [0], [], [], [], [0]],
        frameWeights: [Float],
        startFrame: Int = 0,
        endFrame: Int = 9,
        startTime: Double = 0,
        endTime: Double = 10
    ) -> (PreparedDiarization, DiarizationResult) {
        let weights: [[Float]] = slots.map { active in (0..<3).map { active.contains($0) ? 1 : 0 } }
        let logs: [[Float]] = slots.map { active in
            let index = EvidenceAdapter.powerset.firstIndex(of: active)!
            return (0..<7).map { $0 == index ? 0 : -10 }
        }
        let segmentation = SegmentationOutput(logProbs: [logs], speakerWeights: [weights],
            numChunks: 1, numFrames: slots.count, numSpeakers: 3, chunkOffsets: [0],
            frameDuration: 10.0 / Double(slots.count))
        let embedding = TimedEmbedding(chunkIndex: 0, speakerIndex: 0, startFrame: startFrame,
            endFrame: endFrame, frameWeights: frameWeights, startTime: startTime, endTime: endTime,
            embedding256: vector(0), rho128: [])
        let prepared = PreparedDiarization(
            audioSource: ArrayAudioSampleSource(samples: Array(repeating: 0, count: 32_000)),
            segmentation: segmentation, timedEmbeddings: [embedding], audioLoadingSeconds: 0,
            segmentationSeconds: 0, embeddingExtractionSeconds: 0, prepareWallSeconds: 0)
        let publicEmbeddings = OfflineDiarizerManager.buildPublicChunkEmbeddings(
            timedEmbeddings: [embedding], assignments: [0], logger: AppLogger(category: "PrototypeMaskRegression"))
        return (prepared, DiarizationResult(segments: [], chunkEmbeddings: publicEmbeddings))
    }

    func testSameRunMaskAcceptsCompleteOverlapExcludedEvidence() throws {
        let (prepared, result) = maskValidationFixture(frameWeights: [1, 0, 0, 1, 0, 1, 0, 0, 0, 1])
        let timeline = try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000)
        XCTAssertEqual(timeline.spans[0].speakers, ["S1"])
        XCTAssertEqual(timeline.spans.last?.speakers, ["S1"])
        XCTAssertEqual(timeline.spans.last?.unknownSpeakerCount, 1)
    }

    func testSameRunMaskRejectsEmptyTruncatedExtendedAndAllZeroWeights() throws {
        let invalid: [[Float]] = [
            [], [1, 0, 0, 1, 0, 1, 0, 0, 0],
            [1, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0], Array(repeating: 0, count: 10)
        ]
        for weights in invalid {
            let (prepared, result) = maskValidationFixture(frameWeights: weights)
            XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000)) {
                XCTAssertEqual($0 as? EvidenceError, .assignments)
            }
        }
    }

    func testSameRunMaskRejectsDifferentInteriorsWithIdenticalEndpoints() throws {
        let invalid: [[Float]] = [
            [1, 1, 0, 1, 0, 1, 0, 0, 0, 1], // Incorrectly includes overlap.
            [1, 0, 0, 0, 1, 1, 0, 0, 0, 1], // Same mass/endpoints, shifted interior frame.
            [1, 0, 0, 1, 0, 0, 0, 0, 0, 1]  // Missing supported interior frame.
        ]
        for weights in invalid {
            let (prepared, result) = maskValidationFixture(frameWeights: weights)
            XCTAssertEqual(prepared.timedEmbeddings[0].startTime, result.chunkEmbeddings![0].startTimeSeconds)
            XCTAssertEqual(prepared.timedEmbeddings[0].endTime, result.chunkEmbeddings![0].endTimeSeconds)
            XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000))
        }
    }

    func testSameRunMaskRejectsShiftedFrameBoundsEvenWhenPublicPayloadMatches() throws {
        for (first, last) in [(1, 9), (0, 8), (-1, 9), (0, 10), (9, 0)] {
            let (prepared, result) = maskValidationFixture(
                frameWeights: [1, 0, 0, 1, 0, 1, 0, 0, 0, 1], startFrame: first, endFrame: last)
            XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000))
        }
        let (prepared, result) = maskValidationFixture(
            frameWeights: [1, 0, 0, 1, 0, 1, 0, 0, 0, 1],
            startFrame: 1, endFrame: 8, startTime: 1, endTime: 9)
        XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000))
    }

    func testSameRunMaskRejectsNonfiniteAndNonbinaryInteriorWeights() throws {
        for invalid: Float in [.nan, .infinity, 0.5, -1] {
            var weights: [Float] = [1, 0, 0, 1, 0, 1, 0, 0, 0, 1]
            weights[3] = invalid
            let (prepared, result) = maskValidationFixture(frameWeights: weights)
            XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000))
        }
    }

    func testSameRunMaskRejectsEmbeddingWithoutRequiredCleanSupport() throws {
        let (prepared, result) = maskValidationFixture(
            slots: Array(repeating: [0, 1], count: 10), frameWeights: Array(repeating: 1, count: 10))
        XCTAssertThrowsError(try SDKDiagnosticHarness.reconstruct(prepared, result: result, sampleCount: 32_000))
    }
}
