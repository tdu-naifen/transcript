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
        /// Exact CAM++ artifact revision used by the processor. Leave nil when the
        /// installed artifact cannot be proven; embedding evidence is still produced,
        /// but global identity matching is disabled.
        public var voiceprintModelIdentifier: String?
        public var language: ASRLanguage

        public init(
            asrModelDirectory: URL = ASRModelStore.bundle().directory,
            sortformerModelPath: URL = DiarizationModelStore.sortformerMainModelPath(),
            campPlusDirectory: URL? = DiarizationModelStore.campPlusDirectory(),
            voiceprintModelIdentifier: String? = nil,
            language: ASRLanguage = .auto
        ) {
            self.asrModelDirectory = asrModelDirectory
            self.sortformerModelPath = sortformerModelPath
            self.campPlusDirectory = campPlusDirectory
            self.voiceprintModelIdentifier = voiceprintModelIdentifier
            self.language = language
        }
    }

    public typealias ProgressHandler = @Sendable (MeetingReprocessingProgress) async -> Void

    private final class RunCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    private let database: AppDatabase
    private let deviceId: String
    private let configuration: Configuration
    private let voiceprintProcessor: VoiceprintProcessor?
    private let voiceprintMatcher: VoiceprintMatcher?
    private let canProcessVoiceprints: Bool
    private var isRunning = false
    private var runGeneration = 0
    private var activeRunId: UUID?
    private var activeRunCancellation: RunCancellation?
    private var activeTranscriber: LiveTranscriber?
    private var activeDiarizer: SpeakerDiarizer?
    private var activeVoiceprintHandles: [UUID: VoiceprintJobHandle] = [:]

    /// Creates a single-flight reprocessor. Supplying a long-lived processor permits
    /// model reuse; the matcher must have been created with the exact same nonempty
    /// model revision. A missing revision deliberately disables global matching.
    public init(
        database: AppDatabase,
        deviceId: String,
        configuration: Configuration,
        voiceprintProcessor: VoiceprintProcessor? = nil,
        voiceprintMatcher: VoiceprintMatcher? = nil
    ) {
        self.database = database
        self.deviceId = deviceId
        self.configuration = configuration
        self.canProcessVoiceprints = voiceprintProcessor != nil || configuration.campPlusDirectory.map {
            DiarizationModelStore.isCampPlusInstalled(at: $0)
        } == true
        self.voiceprintProcessor = voiceprintProcessor ?? configuration.campPlusDirectory.flatMap { directory in
            DiarizationModelStore.isCampPlusInstalled(at: directory)
                ? VoiceprintProcessor(modelDirectory: directory)
                : nil
        }
        if let identifier = configuration.voiceprintModelIdentifier, !identifier.isEmpty {
            self.voiceprintMatcher = voiceprintMatcher ?? VoiceprintMatcher(
                speakers: SpeakerRepository(database), modelIdentifier: identifier
            )
        } else {
            self.voiceprintMatcher = nil
        }
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
        runGeneration += 1
        let generation = runGeneration
        let runId = UUID()
        let runCancellation = RunCancellation()
        activeRunId = runId
        activeRunCancellation = runCancellation
        defer {
            isRunning = false
            if activeRunId == runId {
                activeRunId = nil
                activeRunCancellation = nil
                activeTranscriber = nil
                activeDiarizer = nil
                activeVoiceprintHandles.removeAll()
            }
        }

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                await progress(.init(stage: .loadingAudio, fractionCompleted: 0.03))
                let samples = try AudioFileLoader.load16kMono(url: audioURL)
                try Task.checkCancellation()
                let durationMs = max(1, Int(Double(samples.count) / 16_000 * 1_000))
                let oldUtterances = try await UtteranceRepository(database).fetch(meetingId: meetingId)
                let namedSpeakerIds = Set(try await SpeakerRepository(database)
                    .speakers(inMeeting: meetingId)
                    .compactMap { $0.speaker.displayName == nil ? nil : $0.speaker.id })

                let segments = try await transcribe(
                    samples: samples, durationMs: durationMs, meetingId: meetingId, progress: progress
                )
                try ensureActive(runId: runId)
                guard !segments.isEmpty else { throw MeetingReprocessingError.noSpeechDetected }

                let diarization = try await detectSpeakers(
                    samples: samples, durationMs: durationMs, progress: progress
                )
                try ensureActive(runId: runId)
                guard !diarization.isEmpty else {
                    throw MeetingReprocessingError.speakerDetectionFailed("No speaker segments were produced.")
                }

                let speakerDrafts = try await identifySpeakers(
                    meetingId: meetingId,
                    runId: runId,
                    generation: generation,
                    samples: samples,
                    diarization: diarization,
                    oldUtterances: oldUtterances,
                    namedSpeakerIds: namedSpeakerIds,
                    progress: progress
                )
                try Task.checkCancellation()
                try runCancellation.check()
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
                    deviceId: deviceId,
                    cancellationCheck: {
                        try Task.checkCancellation()
                        try runCancellation.check()
                    }
                )
                await progress(.init(stage: .saving, fractionCompleted: 1))
                return MeetingReprocessingSummary(
                    utteranceCount: stored.utteranceCount,
                    speakerCount: stored.speakerCount,
                    identifiedSpeakerCount: Set(speakerDrafts.compactMap {
                        $0.wasVoiceprintMatch ? $0.existingSpeakerId : nil
                    }).count,
                    usedVoiceprintIdentification: speakerDrafts.contains { $0.embedding != nil }
                )
            } onCancel: {
                Task { await self.cancelChildren(runId: runId) }
            }
        } catch is CancellationError {
            await cancelChildren(runId: runId)
            throw CancellationError()
        }
    }

    public func cancel() async {
        guard let activeRunId else { return }
        await cancelChildren(runId: activeRunId)
    }

    private func transcribe(
        samples: [Float],
        durationMs: Int,
        meetingId: String,
        progress: @escaping ProgressHandler
    ) async throws -> [ASRSegment] {
        await progress(.init(stage: .transcribing, fractionCompleted: 0.08))
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        activeDiarizer = nil
        if let failure { throw MeetingReprocessingError.speakerDetectionFailed(failure) }
        return finalized + tentative
    }

    private func identifySpeakers(
        meetingId: String,
        runId: UUID,
        generation: Int,
        samples: [Float],
        diarization: [DiarizerSegment],
        oldUtterances: [Utterance],
        namedSpeakerIds: Set<String>,
        progress: @escaping ProgressHandler
    ) async throws -> [ReprocessedSpeakerDraft] {
        await progress(.init(stage: .identifyingSpeakers, fractionCompleted: 0.82))
        try Task.checkCancellation()
        let indexes = Set(diarization.map(\.speakerIndex)).sorted()
        guard canProcessVoiceprints, let voiceprintProcessor else {
            return indexes.map { index in
                ReprocessedSpeakerDraft(
                    speakerIndex: index,
                    existingSpeakerId: Self.confirmedSpeakerId(
                        for: index, diarization: diarization, oldUtterances: oldUtterances,
                        namedSpeakerIds: namedSpeakerIds
                    )
                )
            }
        }

        do {
            var drafts: [ReprocessedSpeakerDraft] = []
            for (offset, index) in indexes.enumerated() {
                try Task.checkCancellation()
                try ensureActive(runId: runId)
                let confirmedSpeakerId = Self.confirmedSpeakerId(
                    for: index, diarization: diarization, oldUtterances: oldUtterances,
                    namedSpeakerIds: namedSpeakerIds
                )
                let request = try await Self.voiceprintRequest(
                    meetingId: meetingId, generation: generation, speakerIndex: index,
                    samples: samples, diarization: diarization
                )
                guard let request else {
                    drafts.append(.init(speakerIndex: index, existingSpeakerId: confirmedSpeakerId))
                    continue
                }
                let handle = try await voiceprintProcessor.submit(request)
                activeVoiceprintHandles[handle.id] = handle
                let result: VoiceprintProcessingResult
                do {
                    result = try await handle.value()
                } catch {
                    activeVoiceprintHandles[handle.id] = nil
                    throw error
                }
                activeVoiceprintHandles[handle.id] = nil
                try ensureActive(runId: runId)

                drafts.append(try await Self.speakerDraft(
                    speakerIndex: index,
                    confirmedSpeakerId: confirmedSpeakerId,
                    result: result,
                    matcher: voiceprintMatcher
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

    private func ensureActive(runId: UUID) throws {
        try Task.checkCancellation()
        guard activeRunId == runId else { throw CancellationError() }
        try activeRunCancellation?.check()
    }

    nonisolated static func speakerDraft(
        speakerIndex: Int,
        confirmedSpeakerId: String?,
        result: VoiceprintProcessingResult,
        matcher: VoiceprintMatcher?
    ) async throws -> ReprocessedSpeakerDraft {
        let embedding = result.embedding
        var matchedSpeakerId: String?
        if confirmedSpeakerId == nil, let embedding, let matcher,
           case .matched(let speakerId, _) = try await matcher.match(
               embedding: embedding, cleanDuration: result.evidence.cleanDuration
           ) {
            matchedSpeakerId = speakerId
        }
        return ReprocessedSpeakerDraft(
            speakerIndex: speakerIndex,
            existingSpeakerId: confirmedSpeakerId ?? matchedSpeakerId,
            embedding: embedding,
            wasVoiceprintMatch: confirmedSpeakerId == nil && matchedSpeakerId != nil
        )
    }

    private nonisolated static func voiceprintRequest(
        meetingId: String,
        generation: Int,
        speakerIndex: Int,
        samples: [Float],
        diarization: [DiarizerSegment]
    ) async throws -> VoiceprintRequest? {
        try await Task.detached(priority: .utility) {
            do {
                let selected = try VoiceprintSampleSelector().select(
                    speakerIndex: speakerIndex, audio: samples, sampleRate: 16_000,
                    finalizedSegments: diarization
                )
                let segment = DiarizerSegment(
                    speakerIndex: speakerIndex, startFrame: 0, endFrame: selected.samples.count,
                    frameDurationSeconds: 1.0 / 16_000.0
                )
                return VoiceprintRequest(
                    meetingId: meetingId, speakerSlot: speakerIndex,
                    generation: generation, audio: selected.samples, sampleRate: 16_000,
                    finalizedSegments: [segment]
                )
            } catch VoiceprintSampleSelectionError.insufficientCleanAudio {
                return nil
            }
        }.value
    }

    private func cancelChildren(runId: UUID) async {
        guard activeRunId == runId else { return }
        activeRunCancellation?.cancel()
        let handles = Array(activeVoiceprintHandles.values)
        for handle in handles { await handle.cancelAndWait() }
        await activeTranscriber?.cancelAndWait()
        await activeDiarizer?.cancelAndWait()
    }

    private nonisolated static func chunkStream(_ samples: [Float]) -> AsyncStream<AudioChunk> {
        let chunks = AudioFileLoader.chunks(from: samples)
        return AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    nonisolated static func samples(
        forSpeakerIndex index: Int,
        from samples: [Float],
        segments: [DiarizerSegment]
    ) -> [Float] {
        let sampleRate = 16_000.0
        var result: [Float] = []
        for segment in segments where segment.speakerIndex == index {
            let lower = min(samples.count, max(0, Int(Double(segment.startTime) * sampleRate)))
            let upper = min(samples.count, max(lower, Int(Double(segment.endTime) * sampleRate)))
            var cursor = lower
            let overlaps = segments
                .filter { $0.speakerIndex != index }
                .map { other in
                    let overlapLower = min(samples.count, max(lower, Int(Double(other.startTime) * sampleRate)))
                    let overlapUpper = min(samples.count, min(upper, Int(Double(other.endTime) * sampleRate)))
                    return overlapLower..<max(overlapLower, overlapUpper)
                }
                .filter { !$0.isEmpty }
                .sorted { $0.lowerBound < $1.lowerBound }
            for overlap in overlaps {
                if cursor < overlap.lowerBound {
                    result.append(contentsOf: samples[cursor..<overlap.lowerBound])
                }
                cursor = max(cursor, overlap.upperBound)
            }
            if cursor < upper {
                result.append(contentsOf: samples[cursor..<upper])
            }
        }
        return result
    }

    private nonisolated static func confirmedSpeakerId(
        for index: Int,
        diarization: [DiarizerSegment],
        oldUtterances: [Utterance],
        namedSpeakerIds: Set<String>
    ) -> String? {
        let slotSegments = diarization.filter { $0.speakerIndex == index }
        var overlapBySpeaker: [String: Double] = [:]
        for utterance in oldUtterances {
            guard let speakerId = utterance.speakerId, namedSpeakerIds.contains(speakerId) else {
                continue
            }
            let utteranceStart = Double(utterance.startMs) / 1_000
            let utteranceEnd = Double(utterance.endMs) / 1_000
            for segment in slotSegments {
                let overlap = min(utteranceEnd, Double(segment.endTime))
                    - max(utteranceStart, Double(segment.startTime))
                if overlap > 0 { overlapBySpeaker[speakerId, default: 0] += overlap }
            }
        }
        return overlapBySpeaker.max {
            ($0.value, $1.key) < ($1.value, $0.key)
        }?.key
    }
}