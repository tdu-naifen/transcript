@preconcurrency import CoreML
import FluidAudio
import Foundation
import Testing
@testable import TranscriptCore

/// Runs the real queue, sample selector, matcher, and database binding with deterministic
/// inference. These integration checks do not establish CAM++ acoustic accuracy.
@Suite struct VoiceprintDeterministicIntegrationTests {
    @Test func selectedAudioMatchesAndBindsWithoutImplicitEnrollment() async throws {
        let database = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(database)
        let meeting = makeTestMeeting()
        try await MeetingRepository(database).insert(meeting)
        let known = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let binder = VoiceprintBinder(speakers: speakers)
        try await binder.enroll(
            embedding: [1, 0], speakerId: known.id,
            modelIdentifier: "runtime-test-v1", deviceId: testiPhoneId,
            preprocessing: VoiceprintPreprocessing.campPlus
        )
        let expectation = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)
        let generation = try await speakers.voiceprintGeneration()
        let processor = VoiceprintProcessor(inference: VoiceprintInference(
            load: {},
            infer: { samples in
                #expect(samples.count == 32_000)
                #expect(samples.allSatisfy { $0 == 0.25 })
                return [1, 0]
            },
            unload: {}
        ))
        // The last second belongs to another speaker and must never reach inference.
        let handle = try await processor.submit(VoiceprintRequest(
            meetingId: meeting.id, speakerSlot: 0, generation: 42,
            audio: Array(repeating: 0.25, count: 32_000) + Array(repeating: 0.75, count: 16_000),
            sampleRate: 16_000,
            finalizedSegments: [segment(0, 0, 48_000), segment(1, 32_000, 48_000)]
        ))
        let result = try await handle.value()
        await processor.shutdownAndDrain()
        #expect(result.meetingId == meeting.id)
        #expect(result.speakerSlot == 0)
        #expect(result.generation == 42)
        #expect(result.evidence.ranges == [0..<32_000])
        #expect(result.evidence.cleanDuration == 2)
        let embedding = try #require(result.embedding)
        let matcher = VoiceprintMatcher(speakers: speakers, modelIdentifier: "runtime-test-v1")
        let decision = try await matcher.match(
            embedding: embedding, cleanDuration: result.evidence.cleanDuration
        )
        guard case let .matched(speakerID, _) = decision else {
            Issue.record("Expected match from processed clean audio, got \(decision)")
            return
        }
        #expect(speakerID == known.id)
        #expect(try await speakers.speakers(inMeeting: meeting.id).isEmpty)
        try await binder.bindIdentity(
            speakerId: speakerID, meetingId: result.meetingId, speakerIndex: result.speakerSlot,
            expectation: expectation, deviceId: testiPhoneId
        )
        #expect(try await speakers.speakers(inMeeting: meeting.id).map(\.speaker.id) == [known.id])
        #expect(try await speakers.embeddings(forSpeaker: known.id).count == 1)
        #expect(try await speakers.voiceprintGeneration() == generation)
    }

    @Test func insufficientAudioSkipsModelAndShutdownRejectsNewWork() async throws {
        let processor = VoiceprintProcessor(inference: VoiceprintInference(
            load: { Issue.record("Insufficient audio must not load model") },
            infer: { _ in
                Issue.record("Insufficient audio must not run inference")
                return [1, 0]
            },
            unload: { Issue.record("Never-loaded model must not unload") }
        ))
        let request = VoiceprintRequest(
            meetingId: "short", speakerSlot: 0, generation: 1,
            audio: Array(repeating: 0.25, count: 8_000), sampleRate: 16_000,
            finalizedSegments: [segment(0, 0, 8_000)]
        )
        let handle = try await processor.submit(request)
        let result = try await handle.value()
        #expect(result.outcome == .needsMoreAudio)
        #expect(result.embedding == nil)
        #expect(result.evidence.cleanFrameCount == 8_000)
        await processor.shutdownAndDrain()
        await #expect(throws: VoiceprintProcessorError.shutDown) {
            try await processor.submit(request)
        }
        await processor.shutdownAndDrain()
    }

    private func segment(_ speaker: Int, _ start: Int, _ end: Int) -> DiarizerSegment {
        DiarizerSegment(
            speakerIndex: speaker, startFrame: start, endFrame: end,
            frameDurationSeconds: 1.0 / 16_000.0
        )
    }
}

/// Opt-in real local model and LibriSpeech recordings. Two independent utterances from
/// speaker 1089 and one from 1188 are a smoke corpus, not threshold calibration or an EER.
@Suite(.serialized) struct VoiceprintRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BACKEND_REAL_CAMPLUS"] != nil))
    func realCAMPlusColdWarmAndSpeakerComparisons() async throws {
        #if !os(macOS) && !targetEnvironment(simulator)
        throw RealVoiceprintFixtureError("This isolated smoke test requires macOS or an iOS Simulator")
        #else
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios-simulator"
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard environment["BACKEND_REAL_CAMPLUS"] == "1",
              let path = environment["BACKEND_REAL_FIXTURE_DIR"], !path.isEmpty else {
            throw RealVoiceprintFixtureError("Set BACKEND_REAL_CAMPLUS=1 and BACKEND_REAL_FIXTURE_DIR to isolated models/audio fixtures")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        guard CampPlusModels.modelsExist(at: models) else {
            throw RealVoiceprintFixtureError("Requested real CAM++ models are missing from \(models.path)")
        }
        let modelIdentifier = try SpeakerAnalysisEngine.modelIdentifier(at: models)
        let names = ["1089-134686-0000", "1089-134686-0002", "1188-133604-0000"]
        let audio = try names.map { name in
            let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(
                root.appendingPathComponent("audio/\(name).flac")
            )
            guard samples.count >= 80_000, samples.allSatisfy(\.isFinite) else {
                throw RealVoiceprintFixtureError("Real fixture \(name) must contain at least five finite seconds")
            }
            return samples
        }
        let heartbeat = Task { @MainActor in
            var ticks = 0
            var maximumGap = Duration.zero
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                let now = ContinuousClock.now
                maximumGap = max(maximumGap, now - previous)
                previous = now
                ticks += 1
            }
            return (ticks, maximumGap)
        }
        defer { heartbeat.cancel() }
        var generation = 0
        for duration in [1, 2, 3, 5] {
            let frames = duration * 16_000
            let processor = VoiceprintProcessor(
                configuration: .init(
                    minimumSampleDuration: 1, maximumSampleDuration: Double(duration),
                    idleUnloadDelay: .seconds(300)
                ),
                modelDirectory: models
            )
            do {
                let memoryBefore = MemoryFootprint.current()
                let coldStart = ContinuousClock.now
                let enrollment = try await embed(
                    Array(audio[0].prefix(frames)), processor: processor, generation: generation
                )
                generation += 1
                let cold = ContinuousClock.now - coldStart
                let memoryAfter = MemoryFootprint.current()
                var warm: [Duration] = []
                for _ in 0..<3 {
                    let started = ContinuousClock.now
                    let repeated = try await embed(
                        Array(audio[0].prefix(frames)), processor: processor, generation: generation
                    )
                    generation += 1
                    warm.append(ContinuousClock.now - started)
                    #expect(FloatVector.cosineSimilarity(enrollment, repeated) > 0.999)
                }
                let same = try await embed(
                    Array(audio[1].prefix(frames)), processor: processor, generation: generation
                )
                generation += 1
                let different = try await embed(
                    Array(audio[2].prefix(frames)), processor: processor, generation: generation
                )
                generation += 1
                let sameScore = FloatVector.cosineSimilarity(enrollment, same)
                let differentScore = FloatVector.cosineSimilarity(enrollment, different)
                let databaseRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voiceprint-runtime-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: databaseRoot) }
                let database = try AppDatabase.onDisk(directory: databaseRoot)
                let repository = SpeakerRepository(database)
                for (id, vector) in [("1089", enrollment), ("1188", different)] {
                    try await repository.upsert(Speaker(
                        id: id, anonymousName: id, originDeviceId: testiPhoneId
                    ))
                    try await repository.addEmbedding(SpeakerEmbedding(
                        speakerId: id, floats: vector, originDeviceId: testiPhoneId,
                        modelIdentifier: modelIdentifier, preprocessing: VoiceprintPreprocessing.campPlus
                    ))
                }
                let matcher = VoiceprintMatcher(
                    speakers: repository, modelIdentifier: modelIdentifier
                )
                let decision = try await matcher.match(embedding: same, cleanDuration: Double(duration))
                if duration == 1 {
                    guard case .needsMoreAudio = decision else {
                        Issue.record("One second must not assign a persistent identity")
                        throw RealVoiceprintFixtureError("Minimum clean audio policy was bypassed")
                    }
                }
                if duration == 5 {
                    guard case .matched(speakerId: "1089", evidence: let evidence) = decision else {
                        Issue.record("Independent same-speaker speech did not match under the unchanged default policy: \(decision)")
                        throw RealVoiceprintFixtureError("Real same-speaker recognition failed")
                    }
                    let meeting = makeTestMeeting()
                    try await MeetingRepository(database).insert(meeting)
                    let binder = VoiceprintBinder(speakers: repository)
                    let expectation = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)
                    try await binder.bindIdentity(
                        speakerId: "1089", evidence: evidence, meetingId: meeting.id, speakerIndex: 0,
                        expectation: expectation, deviceId: testiPhoneId
                    )
                    try await repository.rename(id: "1089", displayName: "Renamed fixture", deviceId: testiPhoneId)
                    #expect(try await repository.speakers(inMeeting: meeting.id).map(\.speaker.id) == ["1089"])
                    try await MeetingRepository(database).delete(id: meeting.id)
                    try database.writer.close()
                    let reopened = try AppDatabase.onDisk(directory: databaseRoot)
                    let persisted = SpeakerRepository(reopened)
                    #expect(try await persisted.fetch(id: "1089")?.resolvedName == "Renamed fixture")
                    #expect(try await persisted.embeddings(forSpeaker: "1089").count == 1)
                    let reopenedMatcher = VoiceprintMatcher(speakers: persisted, modelIdentifier: modelIdentifier)
                    let afterRestart = try await reopenedMatcher.match(embedding: same, cleanDuration: 5)
                    guard case .matched(speakerId: "1089", evidence: _) = afterRestart else {
                        throw RealVoiceprintFixtureError("Persisted real template did not match after reopen")
                    }
                    let other = try await reopenedMatcher.match(embedding: different, cleanDuration: 5)
                    guard case .matched(speakerId: "1188", evidence: _) = other else {
                        throw RealVoiceprintFixtureError("Different real speaker was not kept separate")
                    }
                    try await persisted.deleteEmbeddings(forSpeaker: "1188", modelIdentifier: modelIdentifier)
                    let unknown = try await reopenedMatcher.match(embedding: different, cleanDuration: 5)
                    guard case .noMatch = unknown else {
                        throw RealVoiceprintFixtureError("Unenrolled real speaker was assigned another identity")
                    }
                    try reopened.writer.close()
                } else {
                    try database.writer.close()
                }
                let memoryDelta = memoryBefore.flatMap { before in memoryAfter.map { $0 - before } }
                let sorted = warm.sorted()
                print("BENCHMARK name=real-camplus platform=\(platform) seconds=\(duration) cold_processor_load_infer_seconds=\(seconds(cold)) warm_p50_seconds=\(seconds(sorted[1])) warm_p95_seconds=\(seconds(sorted[2])) model_memory_delta_bytes=\(memoryDelta.map(String.init) ?? "unavailable") peak_bytes=\(MemoryFootprint.peak().map(String.init) ?? "unavailable") same_speaker_cosine=\(sameScore) different_speaker_cosine=\(differentScore) query=\(names[1]) enrollment=\(names[0]) different=\(names[2]) decision=\(decision)")
                if duration == 5 { #expect(sameScore > differentScore) }
                await processor.shutdownAndDrain()
            } catch {
                await processor.shutdownAndDrain()
                throw error
            }
        }
        heartbeat.cancel()
        let (ticks, gap) = await heartbeat.value
        #expect(ticks > 0)
        print("BENCHMARK name=real-camplus-heartbeat platform=\(platform) main_actor_ticks=\(ticks) maximum_gap_seconds=\(seconds(gap))")
        // Inspect after timing so this extra metadata load does not warm the first processor.
        try inspectModelBounds(models)
        print("BENCHMARK name=real-camplus-complete platform=\(platform) durations=1,2,3,5 fixtures=3 speakers=2 inference=real-camplus calibration=false model=\(modelIdentifier)")
        #endif
    }

    private func embed(
        _ audio: [Float], processor: VoiceprintProcessor, generation: Int
    ) async throws -> [Float] {
        let handle = try await processor.submit(VoiceprintRequest(
            meetingId: "real-camplus", speakerSlot: 0, generation: generation,
            audio: audio, sampleRate: 16_000,
            finalizedSegments: [DiarizerSegment(
                speakerIndex: 0, startFrame: 0, endFrame: audio.count,
                frameDurationSeconds: 1.0 / 16_000.0
            )]
        ))
        let result = try await handle.value()
        let vector = try #require(result.embedding)
        #expect(result.evidence.cleanFrameCount == audio.count)
        #expect(vector.count == 192)
        let allValuesAreFinite = vector.allSatisfy { $0.isFinite }
        #expect(allValuesAreFinite)
        #expect(abs(vector.reduce(Float.zero) { $0 + $1 * $1 } - 1) < 0.001)
        return vector
    }

    private func inspectModelBounds(_ directory: URL) throws {
        let models = try CampPlusModels.load(from: directory)
        let waveform = try #require(models.preprocessor.modelDescription
            .inputDescriptionsByName["waveform"]?.multiArrayConstraint)
        let features = try #require(models.model.modelDescription
            .inputDescriptionsByName["feats"]?.multiArrayConstraint)
        let waveformRanges = waveform.shapeConstraint.sizeRangeForDimension.map(\.rangeValue)
        let featureRanges = features.shapeConstraint.sizeRangeForDimension.map(\.rangeValue)
        try #require(waveformRanges.count == 2)
        try #require(featureRanges.count == 3)
        let waveformRange = waveformRanges[1]
        let featureRange = featureRanges[1]
        #expect(waveformRange.location == 8_000)
        #expect(NSMaxRange(waveformRange) - 1 == 1_600_000)
        #expect(featureRange.location == 64)
        #expect(NSMaxRange(featureRange) - 1 == 6_000)
        // Installed preprocessor uses a 400-frame window and 160-frame stride.
        let jointMinimum = max(waveformRange.location, (featureRange.location - 1) * 160 + 400)
        let jointMaximum = min(NSMaxRange(waveformRange) - 1, (NSMaxRange(featureRange) - 1) * 160 + 399)
        #expect(VoiceprintSampleSelector.modelMinimumFrames == jointMinimum)
        #expect(VoiceprintSampleSelector.modelMaximumFrames == jointMaximum)
        for seconds in [1, 2, 3, 5] {
            #expect(NSLocationInRange(seconds * 16_000, waveformRange))
            #expect(NSLocationInRange((seconds * 16_000 - 400) / 160 + 1, featureRange))
        }
        print("BENCHMARK name=real-camplus-metadata waveform_min=\(waveformRange.location) waveform_max=\(NSMaxRange(waveformRange) - 1) feature_min=\(featureRange.location) feature_max=\(NSMaxRange(featureRange) - 1) joint_min=\(jointMinimum) joint_max=\(jointMaximum)")
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private struct RealVoiceprintFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
