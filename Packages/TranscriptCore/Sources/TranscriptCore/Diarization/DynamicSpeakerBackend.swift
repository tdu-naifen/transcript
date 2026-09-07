import Foundation
import FluidAudio

public struct DynamicSpeakerAnalysis: Sendable {
    public let runID: UUID
    public let timeline: EvidenceTimeline
    public let audioSampleCount: Int
    public let audioSHA256: String?
    public let modelRevision: String
    public let modelLoadingSeconds: TimeInterval
    public let audioLoadingSeconds: TimeInterval
    public let preparationSeconds: TimeInterval
    public let clusteringSeconds: TimeInterval
    public let reconstructionSeconds: TimeInterval

    public var speakerIndices: [Int] {
        Set(timeline.spans.flatMap(\.speakers).compactMap { Int($0.dropFirst()).map { $0 - 1 } }).sorted()
    }

    /// UNKNOWN (-1) is only an exclusion marker, never an identity or voiceprint slot.
    public var segments: [DiarizerSegment] {
        timeline.spans.flatMap { span in
            let indices = span.speakers.compactMap { Int($0.dropFirst()).map { $0 - 1 } }
                + (span.unknownSpeakerCount > 0 ? [-1] : [])
            return indices.map { index in
                DiarizerSegment(speakerIndex: index, startFrame: Int(span.startTick), endFrame: Int(span.endTick),
                                frameDurationSeconds: 1 / Float(timeline.ticksPerSecond))
            }
        }
    }

    /// Integer-rational overlap avoids turning a tiny UNKNOWN boundary into a match.
    public func speakerIndex(startMs: Int, endMs: Int) -> Int? {
        guard startMs >= 0, endMs > startMs,
              endMs <= Int(Int64.max / timeline.ticksPerSecond) else { return nil }
        let lower = Int64(startMs) * timeline.ticksPerSecond
        let upper = Int64(endMs) * timeline.ticksPerSecond
        guard let endTick = timeline.spans.last?.endTick, upper <= endTick * 1_000 else { return nil }
        var speakers: Set<String> = []
        for span in timeline.spans where span.endTick * 1_000 > lower && span.startTick * 1_000 < upper {
            guard span.unknownSpeakerCount == 0 else { return nil }
            speakers.formUnion(span.speakers)
        }
        guard speakers.count == 1, let speaker = speakers.first else { return nil }
        return Int(speaker.dropFirst()).map { $0 - 1 }
    }

    public func cleanEvidence(speakerIndex: Int, minimumDuration: TimeInterval) throws -> VoiceprintSampleEvidence {
        let identity = "S\(speakerIndex + 1)"
        let scale = timeline.ticksPerSecond / 16_000
        var ranges: [Range<Int>] = []
        for span in timeline.spans where span.speakers == [identity] && span.unknownSpeakerCount == 0 {
            let start = Int((span.startTick + scale - 1) / scale)
            let end = min(audioSampleCount, Int(span.endTick / scale))
            guard end > start else { continue }
            if let last = ranges.last, last.upperBound == start {
                ranges[ranges.count - 1] = last.lowerBound..<end
            } else { ranges.append(start..<end) }
        }
        guard minimumDuration.isFinite, minimumDuration > 0, minimumDuration <= 5 else {
            throw VoiceprintSampleSelectionError.invalidConfiguration
        }
        let required = max(VoiceprintSampleSelector.modelMinimumFrames, Int(ceil(minimumDuration * 16_000)))
        let available = ranges.reduce(0) { $0 + $1.count }
        guard available >= required else {
            throw VoiceprintSampleSelectionError.insufficientCleanAudio(requiredFrames: required, availableFrames: available)
        }
        var remaining = 5 * 16_000
        var selected: [Range<Int>] = []
        for range in ranges where remaining > 0 {
            let count = min(remaining, range.count)
            selected.append(range.lowerBound..<(range.lowerBound + count))
            remaining -= count
        }
        return VoiceprintSampleEvidence(ranges: selected, cleanFrameCount: selected.reduce(0) { $0 + $1.count }, sampleRate: 16_000)
    }
}

/// Offline evidence backend. Array input is also usable for bounded provisional
/// windows; its IDs are run-local, NOT stable live IDs across independent calls.
public actor DynamicSpeakerBackend {
    private let modelDirectory: URL
    private let workspace: URL?
    private let cpuOnly: Bool

    public init(modelDirectory: URL, workspace: URL? = nil, cpuOnly: Bool = false) {
        self.modelDirectory = modelDirectory
        self.workspace = workspace
        self.cpuOnly = cpuOnly
    }

    public func analyze(audioURL: URL) async throws -> DynamicSpeakerAnalysis {
        try Task.checkCancellation()
        let hash = try IncrementalSHA256.hashFile(at: audioURL).sha256
        let start = Date()
        let workspace = try self.workspace ?? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "Transcript/DynamicSpeakerAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let raw = workspace.appending(path: "\(UUID().uuidString).pcm")
        guard FileManager.default.createFile(atPath: raw.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: raw) }
        let handle = try FileHandle(forWritingTo: raw)
        defer { try? handle.close() }
        let reader = try RecordedAudioReader(url: audioURL)
        var count = 0
        while let chunk = await reader.next() {
            try Task.checkCancellation()
            guard chunk.samples.allSatisfy(\.isFinite), chunk.startFrame == count,
                  chunk.samples.count <= EvidenceAdapter.maxSamples - count else { throw EvidenceError.bounds }
            try chunk.samples.withUnsafeBytes { try handle.write(contentsOf: $0) }
            count += chunk.samples.count
        }
        try await reader.checkFailure()
        try handle.synchronize()
        try handle.close()
        guard count > 0 else { throw MeetingReprocessingError.noSpeechDetected }
        guard try IncrementalSHA256.hashFile(at: audioURL).sha256 == hash else {
            throw MeetingReprocessingError.speakerDetectionFailed("The recorded audio changed during analysis.")
        }
        let source = MappedAudio(data: try Data(contentsOf: raw, options: .alwaysMapped), sampleCount: count)
        return try await analyze(source: source, audioHash: hash, audioLoadingSeconds: Date().timeIntervalSince(start))
    }

    public func analyze(samples: [Float]) async throws -> DynamicSpeakerAnalysis {
        guard !samples.isEmpty, samples.count <= EvidenceAdapter.maxSamples,
              samples.allSatisfy(\.isFinite) else { throw EvidenceError.bounds }
        return try await analyze(source: ArrayAudioSampleSource(samples: samples), audioHash: nil, audioLoadingSeconds: 0)
    }

    private func analyze(source: any AudioSampleSource, audioHash: String?,
                         audioLoadingSeconds: TimeInterval) async throws -> DynamicSpeakerAnalysis {
        try Task.checkCancellation()
        let start = Date()
        let models = try DynamicSpeakerModelStore.loadVerified(directory: modelDirectory, cpuOnly: cpuOnly)
        let loading = Date().timeIntervalSince(start)
        let manager = OfflineDiarizerManager(config: EvidenceAdapter.configuration())
        manager.initialize(models: models)
        let prepared = try await manager.prepare(audioSource: source)
        try Task.checkCancellation()
        let evidence = try manager.clusterWithEvidence(prepared)
        try Task.checkCancellation()
        let reconstructionStart = Date()
        let timeline = try EvidenceAdapter.reconstruct(evidence)
        try Task.checkCancellation()
        return DynamicSpeakerAnalysis(
            runID: evidence.runID, timeline: timeline, audioSampleCount: source.sampleCount,
            audioSHA256: audioHash, modelRevision: DynamicSpeakerModelStore.revision,
            modelLoadingSeconds: loading, audioLoadingSeconds: audioLoadingSeconds,
            preparationSeconds: evidence.preparationSeconds, clusteringSeconds: evidence.clusteringSeconds,
            reconstructionSeconds: Date().timeIntervalSince(reconstructionStart))
    }

    private struct MappedAudio: AudioSampleSource {
        let data: Data
        let sampleCount: Int

        func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
            try Task.checkCancellation()
            guard offset >= 0, count >= 0, offset <= sampleCount else { throw EvidenceError.bounds }
            let available = min(count, sampleCount - offset)
            guard available > 0 else { return }
            _ = data.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: available * 4),
                               from: (offset * 4)..<((offset + available) * 4))
        }
    }
}
