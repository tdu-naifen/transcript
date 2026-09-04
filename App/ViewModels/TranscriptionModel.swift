import Foundation
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

    private let services: AppServices
    private var transcriber: LiveTranscriber?
    private var eventTask: Task<Void, Never>?

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
    func start(meetingId: String, chunks: AsyncStream<AudioChunk>) {
        guard let engine = services.asrEngine() else {
            status = .modelMissing
            return
        }
        lines.removeAll()
        detectedLanguage = nil
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
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        let transcriber = self.transcriber
        self.transcriber = nil
        Task { await transcriber?.cancel() }
        if status == .running || status == .preparing { status = .idle }
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
        case .failed(let message):
            status = .failed(message)
        case .finished:
            if status == .running || status == .preparing { status = .idle }
        }
    }
}
