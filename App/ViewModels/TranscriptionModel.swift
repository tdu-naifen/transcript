import Foundation
import struct FluidAudio.DiarizerSegment
import Observation
import TranscriptCore

/// Live transcript state for the record screen.
///
/// Apple's speech analyzer runs off the main actor and uses system-managed assets.
@MainActor
@Observable
final class TranscriptionModel {
    enum RecordingError: LocalizedError {
        case processingNotRunning
        case noTranscriptProduced

        var errorDescription: String? {
            switch self {
            case .processingNotRunning: String(localized: "Transcription is not running. Your audio is preserved.")
            case .noTranscriptProduced: String(localized: "No transcript was produced. Your audio is preserved.")
            }
        }
    }

    enum Status: Equatable {
        case modelMissing
        case idle
        case preparing
        case running
        case failed(String)
    }

    /// Newest line first, matching the record screen's layout.
    private(set) var lines: [ASRSegment] = []
    private(set) var status: Status = .idle
    private(set) var computeUnit: String?
    private(set) var detectedLanguage: String?
    private(set) var diarizationSegments: [DiarizerSegment] = []
    private(set) var speakersByIndex: [Int: Speaker] = [:]

    private let services: AppServices
    private var transcriber: (any AppleTranscribing)?
    private let makeTranscriber: () -> any AppleTranscribing
    private var audioOnly = false
    private var diarizer: SpeakerDiarizer?
    private var eventTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private var currentMeetingId: String?
    private var diarizationTimeline = DiarizationTimelineAccumulator()
    private var processingFailure: String?
    private var injectedFinishOperations: (
        asr: @Sendable () async throws -> Void,
        diarization: @Sendable () async throws -> Void
    )?

    init(services: AppServices, makeTranscriber: @escaping () -> any AppleTranscribing = { AppleLiveTranscriber() }) {
        self.services = services
        self.makeTranscriber = makeTranscriber
        self.injectedFinishOperations = nil
        status = .idle
    }

    init(
        services: AppServices,
        meetingId: String,
        asrFinish: @escaping @Sendable () async throws -> Void,
        diarizationFinish: @escaping @Sendable () async throws -> Void
    ) {
        self.services = services
        self.makeTranscriber = { AppleLiveTranscriber() }
        self.injectedFinishOperations = (asr: asrFinish, diarization: diarizationFinish)
        self.currentMeetingId = meetingId
        status = .idle
    }

    var isAvailable: Bool { status != .modelMissing }

    func refreshAvailability() {
        guard status == .idle || status == .modelMissing else { return }
        status = .idle
    }

    func prepare() async throws {
        status = .preparing
        audioOnly = false
        let transcriber = makeTranscriber()
        do {
            try await transcriber.prepare(locale: services.recordingLocale)
            self.transcriber = transcriber
        } catch is CancellationError {
            await transcriber.cancelAndWait()
            status = .idle
            throw CancellationError()
        } catch {
            await transcriber.cancelAndWait()
            if case AppleLiveTranscriber.Failure.resourcesNotReady = error {
                services.speechResources.prepare(locale: services.recordingLocale)
            }
            // Transcription availability must not prevent saving microphone audio.
            self.transcriber = nil
            audioOnly = true
            status = .failed(error.localizedDescription)
        }
    }

    /// `chunks` must be subscribed before capture starts so no chunk is missed while
    /// the model loads; the stream buffers until inference catches up.
    func start(
        meetingId: String,
        chunks: AsyncStream<AudioChunk>,
        diarizationChunks: AsyncStream<AudioChunk>
    ) throws {
        lines.removeAll()
        diarizationSegments.removeAll()
        diarizationTimeline = DiarizationTimelineAccumulator()
        speakersByIndex.removeAll()
        processingFailure = nil
        detectedLanguage = nil
        currentMeetingId = meetingId
        if audioOnly { return }
        guard let transcriber else { throw RecordingError.processingNotRunning }
        status = .preparing
        let store = AppleTranscriptStore(
            repository: UtteranceRepository(services.database),
            meetingID: meetingId, deviceID: services.deviceId
        )

        eventTask = Task { [weak self] in
            let events = await transcriber.events()
            await transcriber.run(chunks: chunks, meetingID: meetingId, services: store)
            for await event in events {
                await self?.apply(event)
            }
        }

        // Speaker attribution is optional; Apple speech never depends on Sortformer.
        let modelPath = DiarizationModelStore.sortformerMainModelPath()
        if DiarizationModelStore.isSortformerInstalled(at: modelPath) {
            startDiarization(meetingId: meetingId, chunks: diarizationChunks, modelPath: modelPath)
        }
    }

    func finish() async throws {
        var failure: (any Error)?
        let finishOperations: (
            asr: @Sendable () async throws -> Void,
            diarization: @Sendable () async throws -> Void
        )
        if audioOnly {
            currentMeetingId = nil
            audioOnly = false
            return
        } else if let transcriber {
            let diarizer = self.diarizer
            finishOperations = (
                asr: { try await transcriber.finishAndWait() },
                diarization: { try await diarizer?.finishAndWait() }
            )
        } else if let injectedFinishOperations {
            finishOperations = injectedFinishOperations
        } else {
            throw RecordingError.processingNotRunning
        }
        do {
            try await LiveRecordingDrain.wait(
                asr: finishOperations.asr,
                diarization: finishOperations.diarization
            )
        } catch {
            failure = error
        }
        await eventTask?.value
        await diarizationTask?.value
        await diarizer?.cleanup()
        if failure == nil, let processingFailure {
            failure = LiveRecordingDrainError(failures: [processingFailure])
        }
        do {
            try await reconcileSpeakerAssignments()
            if injectedFinishOperations != nil { try await requireTranscriptProduced() }
        } catch {
            if failure == nil { failure = error }
            errorMessageForDiarization(String(describing: error))
        }
        eventTask = nil
        diarizationTask = nil
        self.transcriber = nil
        self.diarizer = nil
        injectedFinishOperations = nil
        currentMeetingId = nil
        if let failure {
            status = .failed(String(describing: failure))
            throw failure
        }
        status = .idle
    }

    func discard() async {
        eventTask?.cancel()
        diarizationTask?.cancel()
        await transcriber?.cancelAndWait()
        await diarizer?.cancelAndWait()
        eventTask = nil
        diarizationTask = nil
        transcriber = nil
        diarizer = nil
        currentMeetingId = nil
        if status == .running || status == .preparing { status = .idle }
    }

    func speaker(for segment: ASRSegment) -> Speaker? {
        guard let index = SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: segment.startMs,
            utteranceEndMs: segment.endMs,
            segments: diarizationSegments
        ) else { return nil }
        return speakersByIndex[index]
    }

    private func apply(_ event: ASRTranscriptEvent) async {
        switch event {
        case .ready(let info):
            status = .running
            computeUnit = "Apple Speech"
            detectedLanguage = info.language.fixedLocaleIdentifier
        case .segment(let segment):
            if let existing = lines.firstIndex(where: { $0.id == segment.id }) {
                lines[existing] = segment
            } else if !segment.text.isEmpty {
                lines.insert(segment, at: 0)
            }
            if let locale = segment.localeIdentifier { detectedLanguage = locale }
            if segment.isFinal {
                do {
                    try await reconcileSpeakerAssignments()
                } catch {
                    errorMessageForDiarization(String(describing: error))
                }
            }
        case .failed(let message):
            if processingFailure == nil { processingFailure = message }
            status = .failed(message)
        case .finished:
            if status == .running || status == .preparing { status = .idle }
        }
    }

    private func requireTranscriptProduced() async throws {
        guard let meetingId = currentMeetingId else { return }
        let utterances = try await UtteranceRepository(services.database).fetch(meetingId: meetingId)
        guard !utterances.isEmpty else { throw RecordingError.noTranscriptProduced }
    }

    private func startDiarization(
        meetingId: String,
        chunks: AsyncStream<AudioChunk>,
        modelPath: URL
    ) {
        let diarizer = SpeakerDiarizer(configuration: .init(mainModelPath: modelPath))
        self.diarizer = diarizer
        diarizationTask = Task { [weak self] in
            let events = await diarizer.events()
            await diarizer.run(chunks: chunks)
            for await event in events {
                await self?.apply(event, meetingId: meetingId)
            }
        }
    }

    private func apply(_ event: SpeakerDiarizer.Event, meetingId: String) async {
        switch event {
        case .ready, .finished:
            break
        case .failed(let message):
            if status != .failed(message) {
                errorMessageForDiarization(message)
            }
        case .update(let finalized, let tentative):
            diarizationTimeline.apply(
                finalized: finalized.filter { (0..<4).contains($0.speakerIndex) },
                tentative: tentative.filter { (0..<4).contains($0.speakerIndex) }
            )
            diarizationSegments = diarizationTimeline.segments
            let indexes = Set(diarizationSegments.map(\.speakerIndex)).sorted()
            for index in indexes where speakersByIndex[index] == nil {
                do {
                    let repository = SpeakerRepository(services.database)
                    let speaker = try await repository.createAnonymousSpeaker(deviceId: services.deviceId)
                    try await repository.assignDisplayIndex(
                        meetingId: meetingId,
                        speakerId: speaker.id,
                        displayIndex: index,
                        deviceId: services.deviceId
                    )
                    speakersByIndex[index] = speaker
                } catch {
                    errorMessageForDiarization(String(describing: error))
                }
            }
            do {
                try await reconcileSpeakerAssignments()
            } catch {
                errorMessageForDiarization(String(describing: error))
            }
        }
    }

    private func reconcileSpeakerAssignments() async throws {
        guard let meetingId = currentMeetingId else { return }
        let repository = UtteranceRepository(services.database)
        let utterances = try await repository.fetch(meetingId: meetingId)
        var assignments: [String: String] = [:]
        for utterance in utterances {
            guard let index = SpeakerOverlapAssigner.speakerIndex(
                utteranceStartMs: utterance.startMs,
                utteranceEndMs: utterance.endMs,
                segments: diarizationSegments
            ), let speaker = speakersByIndex[index], utterance.speakerId != speaker.id else { continue }
            assignments[utterance.id] = speaker.id
        }
        if !assignments.isEmpty {
            try await repository.reassignSpeakers(
                meetingId: meetingId,
                assignments: assignments,
                deviceId: services.deviceId
            )
        }
    }

    private func errorMessageForDiarization(_ message: String) {
        if processingFailure == nil { processingFailure = message }
        guard status != .failed(message) else { return }
        status = .failed(message)
    }
}
