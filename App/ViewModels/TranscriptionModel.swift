import Foundation
import struct FluidAudio.DiarizerSegment
import Observation
import TranscriptCore

/// Live transcript state for the record screen.
///
/// Owns nothing heavier than an array of lines: the engine and the ~665 MB of weights
/// live behind ``LiveTranscriber``, an actor, so nothing here ever blocks on inference.
@MainActor
@Observable
final class TranscriptionModel {
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
    private var transcriber: LiveTranscriber?
    private var diarizer: SpeakerDiarizer?
    private var eventTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private var currentMeetingId: String?

    init(services: AppServices) {
        self.services = services
        status = services.isModelInstalled ? .idle : .modelMissing
    }

    var isAvailable: Bool { status != .modelMissing }

    func refreshAvailability() {
        guard status == .idle || status == .modelMissing else { return }
        status = services.isModelInstalled ? .idle : .modelMissing
    }

    /// `chunks` must be subscribed before capture starts so no chunk is missed while
    /// the model loads; the stream buffers until inference catches up.
    func start(
        meetingId: String,
        chunks: AsyncStream<AudioChunk>,
        diarizationChunks: AsyncStream<AudioChunk>
    ) {
        guard let engine = services.asrEngine() else {
            status = .modelMissing
            return
        }
        lines.removeAll()
        diarizationSegments.removeAll()
        speakersByIndex.removeAll()
        detectedLanguage = nil
        currentMeetingId = meetingId
        status = .preparing

        let transcriber = LiveTranscriber(engine: engine, configuration: .init(
            meetingId: meetingId,
            deviceId: services.deviceId,
            utterances: UtteranceRepository(services.database),
            modelDirectory: ASRModelStore.bundle().directory,
            language: services.asrLanguage
        ))
        self.transcriber = transcriber

        eventTask = Task { [weak self] in
            let events = await transcriber.events()
            await transcriber.run(chunks: chunks)
            for await event in events {
                self?.apply(event)
            }
        }

        startDiarization(meetingId: meetingId, chunks: diarizationChunks)
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        diarizationTask?.cancel()
        diarizationTask = nil
        let transcriber = self.transcriber
        let diarizer = self.diarizer
        self.transcriber = nil
        self.diarizer = nil
        Task { await transcriber?.cancel() }
        Task { await diarizer?.cancel() }
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

    private func apply(_ event: ASRTranscriptEvent) {
        switch event {
        case .ready(let info):
            status = .running
            computeUnit = info.dominantComputeUnit
            detectedLanguage = info.language.fixedLocaleIdentifier
        case .segment(let segment):
            if let existing = lines.firstIndex(where: { $0.id == segment.id }) {
                lines[existing] = segment
            } else if !segment.text.isEmpty {
                lines.insert(segment, at: 0)
            }
            if let locale = segment.localeIdentifier { detectedLanguage = locale }
            if segment.isFinal {
                Task { [weak self] in await self?.reconcileSpeakerAssignments() }
            }
        case .failed(let message):
            status = .failed(message)
        case .finished:
            if status == .running || status == .preparing { status = .idle }
        }
    }

    private func startDiarization(meetingId: String, chunks: AsyncStream<AudioChunk>) {
        let modelPath = DiarizationModelStore.sortformerMainModelPath()
        guard DiarizationModelStore.isSortformerInstalled(at: modelPath) else { return }

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
            diarizationSegments = (finalized + tentative).filter { (0..<4).contains($0.speakerIndex) }
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
            await reconcileSpeakerAssignments()
        }
    }

    private func reconcileSpeakerAssignments() async {
        guard let meetingId = currentMeetingId else { return }
        do {
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
        } catch {
            errorMessageForDiarization(String(describing: error))
        }
    }

    private func errorMessageForDiarization(_ message: String) {
        guard status != .failed(message) else { return }
        status = .failed(message)
    }
}
