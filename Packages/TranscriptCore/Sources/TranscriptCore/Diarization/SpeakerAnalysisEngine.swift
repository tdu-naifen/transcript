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
        let dynamicModels = try await downloader.ensureDynamicSpeakersInstalled()
        let campPlus = try await downloader.ensureCampPlusInstalled()
        let modelIdentifier = try Self.modelIdentifier(at: campPlus)
        try Task.checkCancellation()
        await progress(.detectingSpeakers)
        let analysis = try await DynamicSpeakerBackend(modelDirectory: dynamicModels).analyze(audioURL: audioURL)
        let segments = analysis.segments
        let slots = analysis.speakerIndices
        var evidence: [Int: VoiceprintSampleEvidence] = [:]
        for slot in slots {
            do {
                evidence[slot] = try analysis.cleanEvidence(
                    speakerIndex: slot, minimumDuration: VoiceprintMatchPolicy().minimumCleanDuration)
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
        guard try IncrementalSHA256.hashFile(at: audioURL).sha256 == analysis.audioSHA256 else {
            throw MeetingReprocessingError.speakerIdentificationFailed("The recorded audio changed during speaker analysis.")
        }
        await progress(.saving)
        var assignments: [String: Int] = [:]
        var unknown: Set<String> = []
        for utterance in expected {
            if let slot = analysis.speakerIndex(startMs: utterance.startMs, endMs: utterance.endMs) {
                assignments[utterance.id] = slot
            } else {
                unknown.insert(utterance.id)
            }
        }
        try await SpeakerAnalysisRepository(database).apply(
            meetingID: meetingID, expectedUtterances: expected, slotsByUtterance: assignments,
            unknownUtteranceIDs: unknown,
            voices: voices, timeline: segments, modelIdentifier: modelIdentifier,
            deviceID: deviceID, preprocessing: VoiceprintPreprocessing.campPlus
        )
    }

    /// Existing installs may predate revision receipts; bind templates to actual bytes.
    public static func modelIdentifier(at directory: URL) throws -> String {
        func collectFiles(in directory: URL, prefix: String = "") throws -> [(String, URL)] {
            var result: [(String, URL)] = []
            for child in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
                if values.isDirectory == true {
                    result.append(contentsOf: try collectFiles(in: child, prefix: prefix + child.lastPathComponent + "/"))
                } else if values.isRegularFile == true {
                    result.append((prefix + child.lastPathComponent, child))
                }
            }
            return result
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let files = try collectFiles(in: root).sorted { $0.0 < $1.0 }
        guard !files.isEmpty else { throw VoiceprintBindingError.invalidEmbedding }
        var digest = IncrementalSHA256()
        for (relative, file) in files {
            try Task.checkCancellation()
            let hash = try IncrementalSHA256.hashFile(at: file).sha256
            digest.update(Data("\(relative.utf8.count):\(relative):\(hash)\n".utf8))
        }
        return "campplus:\(digest.finalize()):16k:192"
    }
}
