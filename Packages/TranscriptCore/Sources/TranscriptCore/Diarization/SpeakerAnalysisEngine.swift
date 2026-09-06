import Foundation
import FluidAudio

public protocol SpeakerAnalyzing: Actor {
    func run(
        meetingID: String, audioURL: URL,
        progress: @escaping @Sendable (MeetingReprocessingStage) async -> Void
    ) async throws
}

/// A separate, bounded pass over sealed audio. It never invokes a transcription model.
public actor SpeakerAnalysisEngine: SpeakerAnalyzing {
    private let database: AppDatabase
    private let deviceID: String
    private let downloader: ASRModelDownloader

    public init(database: AppDatabase, deviceID: String, downloader: ASRModelDownloader) {
        self.database = database
        self.deviceID = deviceID
        self.downloader = downloader
    }

    public func run(
        meetingID: String, audioURL: URL,
        progress: @escaping @Sendable (MeetingReprocessingStage) async -> Void
    ) async throws {
        let expected = try await UtteranceRepository(database).fetch(meetingId: meetingID)
        await progress(.loadingAudio)
        let sortformer = try await downloader.ensureSortformerInstalled()
        let campPlus = try await downloader.ensureCampPlusInstalled()
        let modelIdentifier = try Self.modelIdentifier(at: campPlus)
        try Task.checkCancellation()
        await progress(.detectingSpeakers)
        let diarizer = SpeakerDiarizer(configuration: .init(mainModelPath: sortformer))
        let reader = try RecordedAudioReader(url: audioURL)
        let events = await diarizer.events()
        await diarizer.run(chunks: AsyncStream(unfolding: { await reader.next() }))
        var timeline = DiarizationTimelineAccumulator()
        do {
            try await withTaskCancellationHandler {
                for await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .update(let finalized, let tentative):
                        timeline.apply(finalized: finalized, tentative: tentative)
                    case .failed(let reason):
                        throw MeetingReprocessingError.speakerDetectionFailed(reason)
                    case .ready, .finished: break
                    }
                }
                try Task.checkCancellation()
                try await diarizer.finishAndWait()
                try await reader.checkFailure()
            } onCancel: {
                Task { await diarizer.cancelAndWait() }
            }
        } catch {
            await diarizer.cancelAndWait()
            await diarizer.cleanup()
            throw error
        }
        await diarizer.cleanup()
        let segments = timeline.segments
        let slots = Set(segments.map(\.speakerIndex)).sorted()
        guard !slots.isEmpty else { throw MeetingReprocessingError.noSpeechDetected }
        let frames = await reader.frameCount
        let selector = VoiceprintSampleSelector(configuration: .init(minimumDuration: VoiceprintMatchPolicy().minimumCleanDuration))
        var evidence: [Int: VoiceprintSampleEvidence] = [:]
        for slot in slots {
            do {
                evidence[slot] = try selector.evidence(
                    speakerIndex: slot, audioFrameCount: frames, sampleRate: 16_000,
                    finalizedSegments: segments
                )
            } catch VoiceprintSampleSelectionError.insufficientCleanAudio {
                // A real diarized turn may be too short for a reliable persistent template.
                continue
            }
        }
        var samples: [Int: [Float]] = [:]
        let secondPass = try RecordedAudioReader(url: audioURL)
        while let chunk = await secondPass.next() {
            try Task.checkCancellation()
            for (slot, selected) in evidence {
                for range in selected.ranges {
                    let lower = max(range.lowerBound, chunk.startFrame)
                    let upper = min(range.upperBound, chunk.startFrame + chunk.samples.count)
                    if lower < upper {
                        samples[slot, default: []].append(contentsOf: chunk.samples[(lower - chunk.startFrame)..<(upper - chunk.startFrame)])
                    }
                }
            }
        }
        try await secondPass.checkFailure()
        await progress(.identifyingSpeakers)
        let processor = VoiceprintProcessor(modelDirectory: campPlus)
        var voices: [DetectedVoiceprint] = []
        do {
            for slot in slots {
                try Task.checkCancellation()
                guard let audio = samples[slot], let selected = evidence[slot] else {
                    voices.append(.init(slot: slot, embedding: nil, cleanDuration: 0))
                    continue
                }
                guard audio.count == selected.cleanFrameCount else {
                    throw MeetingReprocessingError.speakerIdentificationFailed("The recorded audio changed during speaker analysis.")
                }
                let handle = try await processor.submit(VoiceprintRequest(
                    meetingId: meetingID, speakerSlot: slot, generation: 1,
                    audio: audio, sampleRate: 16_000,
                    finalizedSegments: [DiarizerSegment(speakerIndex: slot, startFrame: 0, endFrame: audio.count, frameDurationSeconds: 1 / 16_000)]
                ))
                let result = try await withTaskCancellationHandler {
                    if Task.isCancelled { await handle.cancelAndWait(); throw CancellationError() }
                    return try await handle.value()
                } onCancel: {
                    Task { await handle.cancelAndWait() }
                }
                voices.append(.init(slot: slot, embedding: result.embedding, cleanDuration: selected.cleanDuration))
            }
            await processor.shutdownAndDrain()
        } catch {
            await processor.shutdownAndDrain()
            throw error
        }
        try Task.checkCancellation()
        await progress(.saving)
        var assignments: [String: Int] = [:]
        for utterance in expected {
            assignments[utterance.id] = SpeakerOverlapAssigner.speakerIndex(
                utteranceStartMs: utterance.startMs, utteranceEndMs: utterance.endMs, segments: segments
            )
        }
        try await SpeakerAnalysisRepository(database).apply(
            meetingID: meetingID, expectedUtterances: expected, slotsByUtterance: assignments,
            voices: voices, modelIdentifier: modelIdentifier,
            deviceID: deviceID
        )
    }

    /// Existing installs may predate revision receipts; bind templates to actual bytes.
    static func modelIdentifier(at directory: URL) throws -> String {
        func collectFiles(in directory: URL) throws -> [URL] {
            var result: [URL] = []
            for child in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
                if values.isDirectory == true {
                    result.append(contentsOf: try collectFiles(in: child))
                } else if values.isRegularFile == true {
                    result.append(child)
                }
            }
            return result
        }
        let files = try collectFiles(in: directory).sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw VoiceprintBindingError.invalidEmbedding }
        var digest = IncrementalSHA256()
        for file in files {
            try Task.checkCancellation()
            let relative = String(file.path.dropFirst(directory.path.count + 1))
            let hash = try IncrementalSHA256.hashFile(at: file).sha256
            digest.update(Data("\(relative.utf8.count):\(relative):\(hash)\n".utf8))
        }
        return "campplus:\(digest.finalize()):16k:192"
    }
}
