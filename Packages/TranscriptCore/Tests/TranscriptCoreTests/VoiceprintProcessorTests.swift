import FluidAudio
import Foundation
import Testing

@testable import TranscriptCore

@Suite struct VoiceprintProcessorTests {
  actor Probe {
    var loadCount = 0
    var unloadCount = 0
    var starts: [Int] = []
    var releases = 0
    var waiters: [CheckedContinuation<Void, Never>] = []

    func loaded() { loadCount += 1 }
    func unloaded() { unloadCount += 1 }
    func begin(_ marker: Int) async {
      starts.append(marker)
      if releases > 0 {
        releases -= 1
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }
    func releaseOne() {
      if waiters.isEmpty { releases += 1 } else { waiters.removeFirst().resume() }
    }
    func startCount() -> Int { starts.count }
    func counts() -> (Int, Int) { (loadCount, unloadCount) }
  }

  private func request(_ generation: Int, frames: Int = 16_000) -> VoiceprintRequest {
    VoiceprintRequest(
      meetingId: "meeting",
      speakerSlot: generation,
      generation: generation,
      audio: [Float](repeating: Float(generation), count: frames),
      sampleRate: 16_000,
      finalizedSegments: [
        DiarizerSegment(
          speakerIndex: generation,
          startFrame: 0,
          endFrame: frames,
          frameDurationSeconds: 1.0 / 16_000.0
        )
      ]
    )
  }

  private func processor(
    probe: Probe,
    maximumOutstandingJobs: Int = 4,
    maximumOutstandingFrames: Int = 64_000
  ) -> VoiceprintProcessor {
    VoiceprintProcessor(
      configuration: .init(
        maximumOutstandingJobs: maximumOutstandingJobs,
        maximumOutstandingFrames: maximumOutstandingFrames,
        minimumSampleDuration: 1,
        maximumSampleDuration: 5,
        idleUnloadDelay: .milliseconds(20)
      ),
      inference: VoiceprintInference(
        load: { await probe.loaded() },
        infer: { samples in
          await probe.begin(Int(samples[0]))
          return [samples[0], 1]
        },
        unload: { await probe.unloaded() }
      )
    )
  }

  @Test func queueFullReturnsBusyWithoutWaitingForInference() async throws {
    let probe = Probe()
    let processor = processor(probe: probe, maximumOutstandingJobs: 2)
    let first = try await processor.submit(request(1))
    let second = try await processor.submit(request(2))
    await Task.yield()

    await #expect(throws: VoiceprintProcessorError.busy) {
      try await processor.submit(self.request(3))
    }
    await probe.releaseOne()
    _ = try await first.value()
    await probe.releaseOne()
    _ = try await second.value()
    await processor.shutdownAndDrain()
  }

  @Test func resultCarriesIdentityEmbeddingAndSampleEvidence() async throws {
    let probe = Probe()
    let processor = processor(probe: probe)
    let handle = try await processor.submit(request(7))
    await probe.releaseOne()
    let result = try await handle.value()

    #expect(result.meetingId == "meeting")
    #expect(result.speakerSlot == 7)
    #expect(result.generation == 7)
    let embedding = try #require(result.embedding)
    #expect(abs(embedding[0] - 7 / Float(50).squareRoot()) < 0.0001)
    #expect(abs(embedding[1] - 1 / Float(50).squareRoot()) < 0.0001)
    #expect(result.match == nil)
    #expect(result.evidence.cleanFrameCount == 16_000)
    await processor.shutdownAndDrain()
  }

  @Test func invalidEmbeddingIsRejected() async throws {
    let processor = VoiceprintProcessor(
      inference: VoiceprintInference(
        load: {}, infer: { _ in [.nan, 1] }, unload: {}
      )
    )
    let handle = try await processor.submit(request(1))
    await #expect(throws: VoiceprintProcessorError.invalidEmbedding) {
      try await handle.value()
    }
    await processor.shutdownAndDrain()
  }

  @Test func matcherRunsAfterNormalizedInferenceWithoutWriting() async throws {
    let database = try AppDatabase.inMemory()
    let speakers = SpeakerRepository(database)
    let known = try await speakers.createAnonymousSpeaker(deviceId: "test-device")
    try await speakers.addEmbedding(
      SpeakerEmbedding(
        speakerId: known.id,
        floats: [1, 0],
        originDeviceId: "test-device",
        modelIdentifier: "processor-test"
      ))
    let generation = try await speakers.voiceprintGeneration()
    let matcher = VoiceprintMatcher(
      speakers: speakers,
      modelIdentifier: "processor-test",
      policy: .init(minimumSimilarity: 0.5, minimumMargin: 0.1, minimumCleanDuration: 1)
    )
    let processor = VoiceprintProcessor(
      matcher: matcher,
      inference: VoiceprintInference(
        load: {}, infer: { _ in [2, 0] }, unload: {}
      )
    )

    let result = try await processor.submit(request(1)).value()
    guard case .matched(let speakerId, _)? = result.match else {
      Issue.record("Expected matched processor result")
      await processor.shutdownAndDrain()
      return
    }
    #expect(speakerId == known.id)
    #expect(try await speakers.voiceprintGeneration() == generation)
    await processor.shutdownAndDrain()
  }

  @Test func blockedInferenceDoesNotBlockMainActorOrAdmission() async throws {
    let probe = Probe()
    let processor = processor(probe: probe, maximumOutstandingJobs: 2)
    let first = try await processor.submit(request(1))
    while await probe.startCount() == 0 { await Task.yield() }

    let heartbeat = await MainActor.run { 41 + 1 }
    #expect(heartbeat == 42)
    let second = try await processor.submit(request(2))

    await probe.releaseOne()
    _ = try await first.value()
    await probe.releaseOne()
    _ = try await second.value()
    await processor.shutdownAndDrain()
  }

  @Test func queuedCancellationRemovesJobAndActiveCancellationSuppressesLateResult() async throws {
    let probe = Probe()
    let processor = processor(probe: probe, maximumOutstandingJobs: 2)
    let active = try await processor.submit(request(1))
    let queued = try await processor.submit(request(2))
    await Task.yield()

    await queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value() }
    await active.cancel()
    await #expect(throws: CancellationError.self) { try await active.value() }
    await probe.releaseOne()
    await processor.drain()
    #expect(await probe.startCount() == 1)
    await processor.shutdownAndDrain()
  }

  @Test func modelIsReusedThenUnloadedAfterIdleAndLoadFailureCanRetry() async throws {
    actor Attempts {
      var count = 0
      func load() throws {
        count += 1
        if count == 1 { throw TestError.expected }
      }
    }
    enum TestError: Error { case expected }

    let probe = Probe()
    let attempts = Attempts()
    let processor = VoiceprintProcessor(
      configuration: .init(
        maximumOutstandingJobs: 4,
        maximumOutstandingFrames: 64_000,
        minimumSampleDuration: 1,
        maximumSampleDuration: 1,
        idleUnloadDelay: .milliseconds(20)
      ),
      inference: VoiceprintInference(
        load: {
          try await attempts.load()
          await probe.loaded()
        },
        infer: { [$0[0]] },
        unload: { await probe.unloaded() }
      )
    )

    let failed = try await processor.submit(request(1))
    await #expect(throws: TestError.expected) { try await failed.value() }
    let first = try await processor.submit(request(2))
    _ = try await first.value()
    let second = try await processor.submit(request(3))
    _ = try await second.value()
    #expect((await probe.counts()).0 == 1)

    try await Task.sleep(for: .milliseconds(50))
    #expect((await probe.counts()).1 == 1)
    await processor.shutdownAndDrain()
  }

  @Test func frameCapacityAndDuplicateEvidenceAreRejected() async throws {
    let probe = Probe()
    let processor = processor(probe: probe, maximumOutstandingFrames: 16_000)
    let first = try await processor.submit(request(1))
    await #expect(throws: VoiceprintProcessorError.busy) {
      try await processor.submit(self.request(2))
    }
    await #expect(throws: VoiceprintProcessorError.duplicateEvidence) {
      try await processor.submit(self.request(1))
    }
    await probe.releaseOne()
    _ = try await first.value()
    await processor.shutdownAndDrain()
  }

  @Test func cancelledAndFailedEvidenceCanRetry() async throws {
    actor Attempts {
      var count = 0
      func infer() throws -> [Float] {
        count += 1
        if count == 1 { throw TestError.expected }
        return [1]
      }
    }
    enum TestError: Error { case expected }

    let attempts = Attempts()
    let processor = VoiceprintProcessor(
      inference: VoiceprintInference(
        load: {}, infer: { _ in try await attempts.infer() }, unload: {}
      )
    )
    let failed = try await processor.submit(request(1))
    await #expect(throws: TestError.expected) { try await failed.value() }
    _ = try await processor.submit(request(1)).value()

    let probe = Probe()
    let cancellable = self.processor(probe: probe)
    let cancelled = try await cancellable.submit(request(2))
    await cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value() }
    await probe.releaseOne()
    await cancellable.drain()
    let retried = try await cancellable.submit(request(2))
    await probe.releaseOne()
    _ = try await retried.value()

    await processor.shutdownAndDrain()
    await cancellable.shutdownAndDrain()
  }

  @Test func completedEvidenceHistoryIsBounded() async throws {
    let processor = VoiceprintProcessor(
      configuration: .init(
        maximumOutstandingJobs: 1, maximumOutstandingFrames: 16_000,
        minimumSampleDuration: 1, maximumSampleDuration: 1
      ),
      inference: VoiceprintInference(load: {}, infer: { _ in [1] }, unload: {})
    )
    for version in 0..<17 {
      _ = try await processor.submit(
        VoiceprintRequest(
          meetingId: "meeting", speakerSlot: 0, generation: version, evidenceVersion: version,
          audio: [Float](repeating: 1, count: 16_000), sampleRate: 16_000,
          finalizedSegments: [
            DiarizerSegment(
              speakerIndex: 0, startFrame: 0, endFrame: 16_000,
              frameDurationSeconds: 1.0 / 16_000.0
            )
          ]
        )
      ).value()
    }
    _ = try await processor.submit(
      VoiceprintRequest(
        meetingId: "meeting", speakerSlot: 0, generation: 99, evidenceVersion: 0,
        audio: [Float](repeating: 1, count: 16_000), sampleRate: 16_000,
        finalizedSegments: [
          DiarizerSegment(
            speakerIndex: 0, startFrame: 0, endFrame: 16_000,
            frameDurationSeconds: 1.0 / 16_000.0
          )
        ]
      )
    ).value()
    await processor.shutdownAndDrain()
  }

  @Test func evidenceVersionDeduplicatesAcrossDifferentRuns() async throws {
    let probe = Probe()
    let processor = processor(probe: probe)
    let first = try await processor.submit(
      VoiceprintRequest(
        meetingId: "meeting", speakerSlot: 0, generation: 1, evidenceVersion: 10,
        audio: [Float](repeating: 1, count: 16_000), sampleRate: 16_000,
        finalizedSegments: [
          DiarizerSegment(
            speakerIndex: 0, startFrame: 0, endFrame: 16_000,
            frameDurationSeconds: 1.0 / 16_000.0
          )
        ]
      ))
    await #expect(throws: VoiceprintProcessorError.duplicateEvidence) {
      try await processor.submit(
        VoiceprintRequest(
          meetingId: "meeting", speakerSlot: 0, generation: 2, evidenceVersion: 10,
          audio: [Float](repeating: 1, count: 16_000), sampleRate: 16_000,
          finalizedSegments: [
            DiarizerSegment(
              speakerIndex: 0, startFrame: 0, endFrame: 16_000,
              frameDurationSeconds: 1.0 / 16_000.0
            )
          ]
        ))
    }
    await probe.releaseOne()
    _ = try await first.value()
    await #expect(throws: VoiceprintProcessorError.duplicateEvidence) {
      try await processor.submit(
        VoiceprintRequest(
          meetingId: "meeting", speakerSlot: 0, generation: 3, evidenceVersion: 10,
          audio: [Float](repeating: 1, count: 16_000), sampleRate: 16_000,
          finalizedSegments: [
            DiarizerSegment(
              speakerIndex: 0, startFrame: 0, endFrame: 16_000,
              frameDurationSeconds: 1.0 / 16_000.0
            )
          ]
        ))
    }
    await processor.shutdownAndDrain()
  }
}
