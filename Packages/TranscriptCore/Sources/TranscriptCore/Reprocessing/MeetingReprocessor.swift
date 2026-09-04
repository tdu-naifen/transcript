import FluidAudio
import Foundation

public enum MeetingReprocessingStage: String, Sendable, Equatable {
    case loadingAudio
    case transcribing
    case detectingSpeakers
    case identifyingSpeakers
    case saving
}

public struct MeetingReprocessingProgress: Sendable, Equatable {
    public let stage: MeetingReprocessingStage
    public let fractionCompleted: Double

    public init(stage: MeetingReprocessingStage, fractionCompleted: Double) {
        self.stage = stage
        self.fractionCompleted = min(1, max(0, fractionCompleted))
    }
}

public struct MeetingReprocessingSummary: Sendable, Equatable {
    public let utteranceCount: Int
    public let speakerCount: Int
    public let identifiedSpeakerCount: Int
    public let usedVoiceprintIdentification: Bool
}

public enum MeetingReprocessingError: Error, Sendable, Equatable {
    case alreadyRunning
    case missingASRModel
    case missingDiarizationModel
    case noSpeechDetected
    case transcriptionFailed(String)
    case speakerDetectionFailed(String)
    case speakerIdentificationFailed(String)
}

public actor MeetingReprocessor {
    public struct Configuration: Sendable {
        public var asrModelDirectory: URL
        public var sortformerModelPath: URL
        public var campPlusDirectory: URL?
        public var language: ASRLanguage

        public init(
            asrModelDirectory: URL = ASRModelStore.bundle().directory,
            sortformerModelPath: URL = DiarizationModelStore.sortformerMainModelPath(),
            campPlusDirectory: URL? = DiarizationModelStore.campPlusDirectory(),
            language: ASRLanguage = .auto
        ) {
            self.asrModelDirectory = asrModelDirectory
            self.sortformerModelPath = sortformerModelPath
            self.campPlusDirectory = campPlusDirectory
            self.language = language
        }
    }

    public typealias ProgressHandler = @Sendable (MeetingReprocessingProgress) async -> Void

    private let database: AppDatabase
    private let deviceId: String
    private let configuration: Configuration
    private var isRunning = false
    private var activeTranscriber: LiveTranscriber?
    private var activeDiarizer: SpeakerDiarizer?

    public init(database: AppDatabase, deviceId: String, configuration: Configuration) {
        self.database = database
        self.deviceId = deviceId
        self.configuration = configuration
    }

    public func run(
        meetingId: String,
        audioURL: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> MeetingReprocessingSummary {
        guard !isRunning else { throw MeetingReprocessingError.alreadyRunning }
        guard ASRModelBundle(
            variant: .multilingual2240ms,
            directory: configuration.asrModelDirectory
        ).isInstalled else {
            throw MeetingReprocessingError.missingASRModel
        }
        guard DiarizationModelStore.isSortformerInstalled(at: configuration.sortformerModelPath) else {
            throw MeetingReprocessingError.missingDiarizationModel
        }

        isRunning = true
        defer {
            isRunning = false
            activeTranscriber = nil
            activeDiarizer = nil
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await progress(.init(stage: .loadingAudio, fractionCompleted: 0.03))
            let samples = try AudioFileLoader.load16kMono(url: audioURL)
            try Task.checkCancellation()
            let durationMs = max(1, Int(Double(samples.count) / 16_000 * 1_000))

            let segments = try await transcribe(
                samples: samples, durationMs: durationMs, meetingId: meetingId, progress: progress
            )
            guard !segments.isEmpty else { throw MeetingReprocessingError.noSpeechDetected }

            let diarization = try await detectSpeakers(
                samples: samples, durationMs: durationMs, progress: progress
            )
            guard !diarization.isEmpty else {
                throw MeetingReprocessingError.speakerDetectionFailed("No speaker segments were produced.")
            }

            let speakerDrafts = try await identifySpeakers(
                samples: samples, diarization: diarization, progress: progress
            )
            try Task.checkCancellation()
            let utteranceDrafts = segments.map { segment in
                ReprocessedUtteranceDraft(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    speakerIndex: SpeakerOverlapAssigner.speakerIndex(
                        utteranceStartMs: segment.startMs,
                        utteranceEndMs: segment.endMs,
                        segments: diarization
                    ),
                    localeIdentifier: segment.localeIdentifier
                )
            }

            await progress(.init(stage: .saving, fractionCompleted: 0.97))
            let stored = try await MeetingReprocessingRepository(database).replace(
                meetingId: meetingId,
                utterances: utteranceDrafts,
                speakers: speakerDrafts,
                deviceId: deviceId
            )
            await progress(.init(stage: .saving, fractionCompleted: 1))
            return MeetingReprocessingSummary(
                utteranceCount: stored.utteranceCount,
                speakerCount: stored.speakerCount,
                identifiedSpeakerCount: speakerDrafts.filter { $0.existingSpeakerId != nil }.count,
                usedVoiceprintIdentification: speakerDrafts.contains { $0.embedding != nil }
            )
        } onCancel: {
            Task { await self.cancelChildren() }
        }
    }

    public func cancel() async {
        await cancelChildren()
    }

    private func transcribe(
        samples: [Float],
        durationMs: Int,
        meetingId: String,
        progress: @escaping ProgressHandler
    ) async throws -> [ASRSegment] {
        await progress(.init(stage: .transcribing, fractionCompleted: 0.08))
        let transcriber = LiveTranscriber(
            engine: StreamingNemotronMultilingualAsrManager(),
            configuration: .init(
                meetingId: meetingId,
                deviceId: deviceId,
                utterances: nil,
                modelDirectory: configuration.asrModelDirectory,
                language: configuration.language
            )
        )
        activeTranscriber = transcriber
        let events = await transcriber.events()
        await transcriber.run(chunks: Self.chunkStream(samples))
        var completed: [String: ASRSegment] = [:]
        var failure: String?
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .segment(let segment) where segment.isFinal && !segment.text.isEmpty:
                completed[segment.id] = segment
                let audioFraction = min(1, Double(segment.endMs) / Double(durationMs))
                await progress(.init(stage: .transcribing, fractionCompleted: 0.08 + audioFraction * 0.42))
            case .failed(let message):
                failure = message
            default:
                break
            }
        }
        activeTranscriber = nil
        if let failure { throw MeetingReprocessingError.transcriptionFailed(failure) }
        return completed.values.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
    }

    private func detectSpeakers(
        samples: [Float],
        durationMs: Int,
        progress: @escaping ProgressHandler
    ) async throws -> [DiarizerSegment] {
        await progress(.init(stage: .detectingSpeakers, fractionCompleted: 0.52))
        let diarizer = SpeakerDiarizer(configuration: .init(
            mainModelPath: configuration.sortformerModelPath
        ))
        activeDiarizer = diarizer
        let events = await diarizer.events()
        await diarizer.run(chunks: Self.chunkStream(samples))
        var finalized: [DiarizerSegment] = []
        var tentative: [DiarizerSegment] = []
        var failure: String?
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .update(let newFinalized, let newTentative):
                finalized.append(contentsOf: newFinalized.filter { (0..<4).contains($0.speakerIndex) })
                tentative = newTentative.filter { (0..<4).contains($0.speakerIndex) }
                let endMs = Int(((finalized + tentative).map(\.endTime).max() ?? 0) * 1_000)
                let audioFraction = min(1, Double(endMs) / Double(durationMs))
                await progress(.init(
                    stage: .detectingSpeakers, fractionCompleted: 0.52 + audioFraction * 0.28
                ))
            case .failed(let message):
                failure = message
            default:
                break
            }
        }
        activeDiarizer = nil
        if let failure { throw MeetingReprocessingError.speakerDetectionFailed(failure) }
        return finalized + tentative
    }

    private func identifySpeakers(
        samples: [Float],
        diarization: [DiarizerSegment],
        progress: @escaping ProgressHandler
    ) async throws -> [ReprocessedSpeakerDraft] {
        await progress(.init(stage: .identifyingSpeakers, fractionCompleted: 0.82))
        let indexes = Set(diarization.map(\.speakerIndex)).sorted()
        guard let directory = configuration.campPlusDirectory,
              DiarizationModelStore.isCampPlusInstalled(at: directory) else {
            return indexes.map { ReprocessedSpeakerDraft(speakerIndex: $0) }
        }

        do {
            let embedder = CampPlusEmbedder(models: try CampPlusModels.load(from: directory))
            let speakers = SpeakerRepository(database)
            var drafts: [ReprocessedSpeakerDraft] = []
            for (offset, index) in indexes.enumerated() {
                try Task.checkCancellation()
                let slotSamples = Self.samples(
                    forSpeakerIndex: index, from: samples, segments: diarization
                )
                guard !slotSamples.isEmpty else {
                    drafts.append(ReprocessedSpeakerDraft(speakerIndex: index))
                    continue
                }
                let embedding = try await embedder.embed(audio: slotSamples)
                let match = try await speakers.findNearestSpeaker(
                    embedding: embedding, threshold: voiceprintMatchThreshold
                )
                drafts.append(ReprocessedSpeakerDraft(
                    speakerIndex: index,
                    existingSpeakerId: match?.speakerId,
                    embedding: embedding
                ))
                let fraction = Double(offset + 1) / Double(max(1, indexes.count))
                await progress(.init(
                    stage: .identifyingSpeakers, fractionCompleted: 0.82 + fraction * 0.13
                ))
            }
            return drafts
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MeetingReprocessingError.speakerIdentificationFailed(String(describing: error))
        }
    }

    private func cancelChildren() async {
        await activeTranscriber?.cancel()
        await activeDiarizer?.cancel()
    }

    private nonisolated static func chunkStream(_ samples: [Float]) -> AsyncStream<AudioChunk> {
        let chunks = AudioFileLoader.chunks(from: samples)
        return AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private nonisolated static func samples(
        forSpeakerIndex index: Int,
        from samples: [Float],
        segments: [DiarizerSegment]
    ) -> [Float] {
        let sampleRate = 16_000.0
        var result: [Float] = []
        for segment in segments where segment.speakerIndex == index {
            let lower = min(samples.count, max(0, Int(Double(segment.startTime) * sampleRate)))
            let upper = min(samples.count, max(lower, Int(Double(segment.endTime) * sampleRate)))
            result.append(contentsOf: samples[lower..<upper])
        }
        return result
    }
}