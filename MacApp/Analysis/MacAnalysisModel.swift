import Foundation
import Observation

@MainActor
@Observable
final class MacAnalysisModel {
    var mode: MacAnalysisMode = .chat {
        didSet { if mode != oldValue { clearSession() } }
    }
    var selectedMeetingID: String? {
        didSet { if selectedMeetingID != oldValue { clearSession() } }
    }
    var question = ""
    private(set) var availability: MacAnalysisAvailability = .checking
    private(set) var isGenerating = false
    private(set) var result: MacAnalysisResult?
    private(set) var lastQuestion: String?
    private(set) var errorMessage: String?
    private(set) var history: [MacAnalysisTurn] = []
    @ObservationIgnored private let backend: any MacAnalysisGenerating
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var generationID = UUID()
    @ObservationIgnored private var corpusFingerprint: String?

    init(backend: any MacAnalysisGenerating = MacFoundationModelsBackend()) {
        self.backend = backend
    }

    func refreshAvailability() async {
        availability = await backend.availability()
    }

    func updateCorpus(_ items: [MacLibraryItem]) {
        let fingerprint = MacAnalysisEvidence.fingerprint(items)
        let changed = corpusFingerprint != nil && corpusFingerprint != fingerprint
        if changed {
            clearSession()
        }
        corpusFingerprint = fingerprint
        if let selectedMeetingID, !items.contains(where: { $0.id == selectedMeetingID }) {
            self.selectedMeetingID = nil
        }
        if changed {
            errorMessage = String(localized: "The saved library changed. Previous answers and references were cleared.")
        }
    }

    func send(items: [MacLibraryItem]) {
        guard !isGenerating else { return }
        updateCorpus(items)
        guard availability == .available else {
            errorMessage = availability.message
            return
        }
        let input = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty || mode == .summary else { return }
        guard input.utf8.count <= MacAnalysisEvidence.maximumQuestionBytes else {
            errorMessage = MacAnalysisError.questionTooLong.localizedDescription
            return
        }
        errorMessage = nil
        result = nil
        lastQuestion = input.isEmpty ? String(localized: "Summarize this meeting") : input
        isGenerating = true
        let id = UUID()
        generationID = id
        let mode = mode
        let selectedMeetingID = selectedMeetingID
        let history = history
        let backend = backend
        generation = Task { [weak self] in
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try MacAnalysisEvidence.prepare(
                        mode: mode, question: input, meetingID: selectedMeetingID, items: items, history: history
                    )
                }
                let request = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                let raw = try await backend.generate(request)
                try Task.checkCancellation()
                let answer = try MacAnalysisEvidence.validate(raw, request: request)
                guard let self, self.generationID == id else { return }
                self.result = answer
                if mode == .chat {
                    self.history.append(MacAnalysisTurn(question: input, answer: answer.paragraphs.map(\.text).joined(separator: "\n")))
                    while self.history.count > 4 || self.history.reduce(0, { $0 + $1.question.utf8.count + $1.answer.utf8.count }) > 2_000 {
                        self.history.removeFirst()
                    }
                }
                self.question = ""
                self.isGenerating = false
                self.generation = nil
            } catch {
                guard let self, self.generationID == id else { return }
                self.isGenerating = false
                self.generation = nil
                if error is CancellationError {
                    self.errorMessage = String(localized: "Generation cancelled.")
                } else {
                    self.errorMessage = MacAnalysisEvidence.prefix(error.localizedDescription, bytes: 700)
                }
            }
        }
    }

    func cancel() {
        if isGenerating { errorMessage = String(localized: "Generation cancelled.") }
        generationID = UUID()
        generation?.cancel()
        generation = nil
        isGenerating = false
    }

    func clearSession() {
        cancel()
        question = ""
        result = nil
        history = []
        lastQuestion = nil
        errorMessage = nil
    }

    func dismissError() { errorMessage = nil }
}
