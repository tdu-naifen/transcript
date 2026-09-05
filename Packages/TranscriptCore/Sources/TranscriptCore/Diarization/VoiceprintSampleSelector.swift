import FluidAudio
import Foundation

public enum VoiceprintSampleSelectionError: Error, Equatable, Sendable {
  case unsupportedSampleRate(Int)
  case invalidConfiguration
  case nonFiniteAudio
  case insufficientCleanAudio(requiredFrames: Int, availableFrames: Int)
}

public struct VoiceprintSampleEvidence: Sendable, Equatable {
  public let ranges: [Range<Int>]
  public let cleanFrameCount: Int
  public let sampleRate: Int

  public var cleanDuration: TimeInterval { Double(cleanFrameCount) / Double(sampleRate) }

  public init(ranges: [Range<Int>], cleanFrameCount: Int, sampleRate: Int) {
    self.ranges = ranges
    self.cleanFrameCount = cleanFrameCount
    self.sampleRate = sampleRate
  }
}

public struct VoiceprintSelectedSample: Sendable, Equatable {
  public let samples: [Float]
  public let evidence: VoiceprintSampleEvidence
}

/// Selects clean, finalized 16 kHz mono audio for one diarization slot.
/// Target intervals are unioned before other-speaker intervals are subtracted, so a
/// source frame is copied at most once and retained ranges remain chronological.
public struct VoiceprintSampleSelector: Sendable {
  public struct Configuration: Sendable, Equatable {
    public var minimumDuration: TimeInterval
    public var maximumDuration: TimeInterval

    public init(minimumDuration: TimeInterval = 1, maximumDuration: TimeInterval = 5) {
      self.minimumDuration = minimumDuration
      self.maximumDuration = maximumDuration
    }
  }

  public static let sampleRate = 16_000
  public static let modelMinimumFrames = 10_480
  public static let modelMaximumFrames = 960_399

  public let configuration: Configuration

  public init(configuration: Configuration = .init()) {
    self.configuration = configuration
  }

  public func select(
    speakerIndex: Int,
    audio: [Float],
    sampleRate: Int,
    finalizedSegments: [DiarizerSegment]
  ) throws -> VoiceprintSelectedSample {
    guard sampleRate == Self.sampleRate else {
      throw VoiceprintSampleSelectionError.unsupportedSampleRate(sampleRate)
    }
    guard configuration.minimumDuration.isFinite,
      configuration.maximumDuration.isFinite,
      configuration.minimumDuration > 0,
      configuration.maximumDuration >= configuration.minimumDuration
    else {
      throw VoiceprintSampleSelectionError.invalidConfiguration
    }
    guard
      let requestedMinimum = frameCount(
        seconds: configuration.minimumDuration, sampleRate: sampleRate, rule: .up),
      let requestedMaximum = frameCount(
        seconds: configuration.maximumDuration, sampleRate: sampleRate, rule: .down)
    else {
      throw VoiceprintSampleSelectionError.invalidConfiguration
    }
    let minimumFrames = max(Self.modelMinimumFrames, requestedMinimum)
    let maximumFrames = min(Self.modelMaximumFrames, requestedMaximum)
    guard minimumFrames <= maximumFrames else {
      throw VoiceprintSampleSelectionError.invalidConfiguration
    }

    let valid = finalizedSegments.filter(\.isFinalized)
    let target = union(
      valid.filter { $0.speakerIndex == speakerIndex }.compactMap {
        frameRange(for: $0, sampleRate: sampleRate, audioCount: audio.count, isExclusion: false)
      })
    let excluded = union(
      valid.filter { $0.speakerIndex != speakerIndex }.compactMap {
        frameRange(for: $0, sampleRate: sampleRate, audioCount: audio.count, isExclusion: true)
      })
    let clean = subtract(excluded, from: target)
    let available = clean.reduce(0) { $0 + $1.count }
    guard available >= minimumFrames else {
      throw VoiceprintSampleSelectionError.insufficientCleanAudio(
        requiredFrames: minimumFrames,
        availableFrames: available
      )
    }

    var remaining = maximumFrames
    var selectedRanges: [Range<Int>] = []
    var samples: [Float] = []
    samples.reserveCapacity(min(available, maximumFrames))
    for range in clean where remaining > 0 {
      let end = min(range.upperBound, range.lowerBound + remaining)
      let selected = range.lowerBound..<end
      guard audio[selected].allSatisfy(\.isFinite) else {
        throw VoiceprintSampleSelectionError.nonFiniteAudio
      }
      selectedRanges.append(selected)
      samples.append(contentsOf: audio[selected])
      remaining -= selected.count
    }
    return VoiceprintSelectedSample(
      samples: samples,
      evidence: VoiceprintSampleEvidence(
        ranges: selectedRanges,
        cleanFrameCount: samples.count,
        sampleRate: sampleRate
      )
    )
  }

  private func frameRange(
    for segment: DiarizerSegment,
    sampleRate: Int,
    audioCount: Int,
    isExclusion: Bool
  ) -> Range<Int>? {
    let start = Double(segment.startTime) * Double(sampleRate)
    let end = Double(segment.endTime) * Double(sampleRate)
    guard start.isFinite, end.isFinite, end > start else { return nil }
    let lowerValue = start.rounded(isExclusion ? .down : .up)
    let upperValue = end.rounded(isExclusion ? .up : .down)
    guard let lower = boundedFrame(lowerValue, audioCount: audioCount),
      let upper = boundedFrame(upperValue, audioCount: audioCount)
    else { return nil }
    return lower < upper ? lower..<upper : nil
  }

  private func frameCount(
    seconds: TimeInterval,
    sampleRate: Int,
    rule: FloatingPointRoundingRule
  ) -> Int? {
    let frames = (seconds * Double(sampleRate)).rounded(rule)
    guard frames.isFinite, frames >= 0, frames <= Double(Int.max) else { return nil }
    return Int(frames)
  }

  private func boundedFrame(_ value: Double, audioCount: Int) -> Int? {
    guard value.isFinite else { return nil }
    if value <= 0 { return 0 }
    if value >= Double(audioCount) { return audioCount }
    guard value <= Double(Int.max) else { return nil }
    return Int(value)
  }

  private func union(_ ranges: [Range<Int>]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for range in ranges.sorted(by: {
      ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound)
    }) {
      guard let last = result.last, range.lowerBound <= last.upperBound else {
        result.append(range)
        continue
      }
      result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
    }
    return result
  }

  private func subtract(_ excluded: [Range<Int>], from included: [Range<Int>]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var exclusionIndex = 0
    for range in included {
      var cursor = range.lowerBound
      while exclusionIndex < excluded.count && excluded[exclusionIndex].upperBound <= cursor {
        exclusionIndex += 1
      }
      var index = exclusionIndex
      while index < excluded.count && excluded[index].lowerBound < range.upperBound {
        let overlap = excluded[index]
        if cursor < overlap.lowerBound {
          result.append(cursor..<min(overlap.lowerBound, range.upperBound))
        }
        cursor = max(cursor, overlap.upperBound)
        if cursor >= range.upperBound { break }
        index += 1
      }
      if cursor < range.upperBound { result.append(cursor..<range.upperBound) }
    }
    return result
  }
}
