import FluidAudio
import Testing

@testable import TranscriptCore

@Suite struct VoiceprintSampleSelectorTests {
  private func segment(
    _ speaker: Int,
    _ start: Int,
    _ end: Int,
    finalized: Bool = true
  ) -> DiarizerSegment {
    DiarizerSegment(
      speakerIndex: speaker,
      startFrame: start,
      endFrame: end,
      finalized: finalized,
      frameDurationSeconds: 1.0 / 16_000.0
    )
  }

  @Test func unionsTargetIntervalsAndSubtractsOtherSpeakersWithoutDuplicates() throws {
    let audio = (0..<80_000).map(Float.init)
    let selected = try VoiceprintSampleSelector(
      configuration: .init(minimumDuration: 1, maximumDuration: 5)
    )
    .select(
      speakerIndex: 0,
      audio: audio,
      sampleRate: 16_000,
      finalizedSegments: [
        segment(0, 0, 24_000),
        segment(0, 16_000, 48_000),
        segment(1, 8_000, 12_000),
        segment(1, 20_000, 28_000),
      ]
    )

    #expect(selected.evidence.ranges == [0..<8_000, 12_000..<20_000, 28_000..<48_000])
    #expect(selected.evidence.cleanFrameCount == 36_000)
    #expect(
      selected.samples == Array(audio[0..<8_000]) + Array(audio[12_000..<20_000])
        + Array(audio[28_000..<48_000]))
  }

  @Test func ignoresTentativeSegmentsClipsBoundsAndReturnsChronologicalSamples() throws {
    let audio = (0..<48_000).map(Float.init)
    let selected = try VoiceprintSampleSelector(
      configuration: .init(minimumDuration: 1, maximumDuration: 3)
    )
    .select(
      speakerIndex: 2,
      audio: audio,
      sampleRate: 16_000,
      finalizedSegments: [
        segment(2, 32_000, 64_000),
        segment(2, -8_000, 8_000),
        segment(2, 8_000, 16_000, finalized: false),
      ]
    )

    #expect(selected.evidence.ranges == [0..<8_000, 32_000..<48_000])
    #expect(selected.samples.first == 0)
    #expect(selected.samples.last == 47_999)
  }

  @Test(arguments: [1.0, 2.0, 3.0, 5.0])
  func configurableCapStopsAtRequestedDuration(_ seconds: Double) throws {
    let audio = [Float](repeating: 0.25, count: 96_000)
    let selected = try VoiceprintSampleSelector(
      configuration: .init(minimumDuration: 1, maximumDuration: seconds)
    )
    .select(
      speakerIndex: 0,
      audio: audio,
      sampleRate: 16_000,
      finalizedSegments: [segment(0, 0, audio.count)]
    )

    #expect(selected.samples.count == Int(seconds * 16_000))
    #expect(selected.evidence.ranges == [0..<Int(seconds * 16_000)])
  }

  @Test func roundsTargetsInwardAndExclusionsOutward() throws {
    let audio = (0..<32_000).map(Float.init)
    let selected = try VoiceprintSampleSelector(
      configuration: .init(minimumDuration: 0.7, maximumDuration: 2)
    ).select(
      speakerIndex: 0,
      audio: audio,
      sampleRate: 16_000,
      finalizedSegments: [
        DiarizerSegment(
          speakerIndex: 0, startFrame: 1, endFrame: 16_001,
          frameDurationSeconds: 1.5 / 16_000.0
        ),
        DiarizerSegment(
          speakerIndex: 1, startFrame: 20_001, endFrame: 22_001,
          frameDurationSeconds: 0.5 / 16_000.0
        ),
      ]
    )

    #expect(selected.evidence.ranges == [2..<10_000, 11_001..<24_001])
    #expect(selected.samples.first == 2)
  }

  @Test func rejectsUnrepresentableDurationAndIgnoresUnrepresentableSegmentTime() throws {
    let audio = [Float](repeating: 0, count: 16_000)
    #expect(throws: VoiceprintSampleSelectionError.invalidConfiguration) {
      try VoiceprintSampleSelector(
        configuration: .init(minimumDuration: 1, maximumDuration: .greatestFiniteMagnitude)
      ).select(
        speakerIndex: 0, audio: audio, sampleRate: 16_000,
        finalizedSegments: [segment(0, 0, 16_000)]
      )
    }

    let oversized = DiarizerSegment(
      speakerIndex: 0, startFrame: Int.max / 2, endFrame: Int.max,
      frameDurationSeconds: .greatestFiniteMagnitude
    )
    #expect(
      throws: VoiceprintSampleSelectionError.insufficientCleanAudio(
        requiredFrames: 16_000, availableFrames: 0)
    ) {
      try VoiceprintSampleSelector().select(
        speakerIndex: 0, audio: audio, sampleRate: 16_000,
        finalizedSegments: [oversized]
      )
    }
  }

  @Test func insufficientCleanSpeechIsNotPadded() throws {
    let selector = VoiceprintSampleSelector(
      configuration: .init(minimumDuration: 1, maximumDuration: 5))
    #expect(
      throws: VoiceprintSampleSelectionError.insufficientCleanAudio(
        requiredFrames: 16_000, availableFrames: 15_999)
    ) {
      try selector.select(
        speakerIndex: 0,
        audio: [Float](repeating: 0, count: 15_999),
        sampleRate: 16_000,
        finalizedSegments: [segment(0, 0, 15_999)]
      )
    }
  }

  @Test func rejectsWrongSampleRateAndNonFiniteSelectedAudio() {
    let selector = VoiceprintSampleSelector()
    #expect(throws: VoiceprintSampleSelectionError.unsupportedSampleRate(8_000)) {
      try selector.select(
        speakerIndex: 0,
        audio: [Float](repeating: 0, count: 16_000),
        sampleRate: 8_000,
        finalizedSegments: [segment(0, 0, 16_000)]
      )
    }

    var audio = [Float](repeating: 0, count: 16_000)
    audio[100] = .infinity
    #expect(throws: VoiceprintSampleSelectionError.nonFiniteAudio) {
      try selector.select(
        speakerIndex: 0,
        audio: audio,
        sampleRate: 16_000,
        finalizedSegments: [segment(0, 0, 16_000)]
      )
    }
  }
}
