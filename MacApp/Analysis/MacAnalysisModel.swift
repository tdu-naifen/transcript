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
    var configuration: MacAnalysisConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            clearSession()
            cancelDownload()
            retryDownloadEmbedding = nil
            semanticIndex = MacAnalysisSemanticIndex()
            configureBackends()
            availability = .checking
            if persistsConfiguration { configuration.save() }
            Task { await refreshAvailability() }
        }
    }
    private(set) var retrievalStatus: String?
    private(set) var downloadProgress: Double?
    private(set) var downloadStatus: String?
    private(set) var retryDownloadEmbedding: Bool?
    private var downloadingEmbedding: Bool?
    @ObservationIgnored private var backend: any MacAnalysisGenerating
    @ObservationIgnored private var embedding: (any MacAnalysisEmbedding)?
    @ObservationIgnored private let injectedBackend: (any MacAnalysisGenerating)?
    @ObservationIgnored private let injectedEmbedding: (any MacAnalysisEmbedding)?
    @ObservationIgnored private let persistsConfiguration: Bool
    @ObservationIgnored private var semanticIndex = MacAnalysisSemanticIndex()
    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var downloadID = UUID()
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var generationID = UUID()
    @ObservationIgnored private var corpusFingerprint: String?

    init(
        backend: (any MacAnalysisGenerating)? = nil,
        embedding: (any MacAnalysisEmbedding)? = nil,
        configuration: MacAnalysisConfiguration? = nil
    ) {
        self.injectedBackend = backend
        self.injectedEmbedding = embedding
        self.persistsConfiguration = backend == nil && configuration == nil
        self.configuration = configuration ?? (backend == nil ? .load() : MacAnalysisConfiguration())
        self.backend = backend ?? MacFoundationModelsBackend()
        configureBackends()
    }

    private func configureBackends() {
        backend = injectedBackend ?? (configuration.languageModel == .apple
            ? MacFoundationModelsBackend() as any MacAnalysisGenerating
            : MacMLXLanguageBackend(location: configuration.llm))
        switch configuration.embeddingModel {
        case .keyword: embedding = nil
        case .appleEnglish: embedding = injectedEmbedding ?? MacAppleSentenceEmbedding()
        case .mlx: embedding = injectedEmbedding ?? MacMLXEmbeddingBackend(location: configuration.embedding)
        }
    }

    func refreshAvailability() async {
        let current = configuration
        let state = await backend.availability()
        guard current == configuration else { return }
        availability = state
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
            errorMessage = analysisText("The saved library changed. Previous answers and references were cleared.")
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
        retrievalStatus = nil
        lastQuestion = input.isEmpty ? analysisText("Summarize this meeting") : input
        isGenerating = true
        let id = UUID()
        generationID = id
        let mode = mode
        let selectedMeetingID = selectedMeetingID
        let history = history
        let backend = backend
        let embedding = embedding
        let semanticIndex = semanticIndex
        generation = Task { [weak self] in
            do {
                var retrieval: MacAnalysisRetrievalResult?
                if mode == .rag, let embedding {
                    self?.retrievalStatus = analysisText("Building/searching bounded in-memory sentence index…")
                    retrieval = try await semanticIndex.retrieve(
                        question: input, meetingID: selectedMeetingID, items: items, embedding: embedding
                    )
                    try Task.checkCancellation()
                }
                let semanticRanking = retrieval?.ranked
                let preparation = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try MacAnalysisEvidence.prepare(
                        mode: mode, question: input, meetingID: selectedMeetingID, items: items, history: history,
                        semanticRanking: semanticRanking
                    )
                }
                let request = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.generationID == id else { return }
                if let retrieval {
                    self.retrievalStatus = analysisText("Semantic index: \(retrieval.indexed)/\(retrieval.total) nonempty utterances, first 550 UTF-8 bytes each. Memory only; rebuilt after changes. Excerpts are not exhaustive.")
                }
                let raw = try await backend.generate(request)
                try Task.checkCancellation()
                let answer = try MacAnalysisEvidence.validate(raw, request: request)
                guard self.generationID == id else { return }
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
                    self.errorMessage = analysisText("Generation cancelled.")
                } else {
                    self.errorMessage = MacAnalysisEvidence.prefix(error.localizedDescription, bytes: 700)
                }
            }
        }
    }

    func cancel() {
        if isGenerating { errorMessage = analysisText("Generation cancelled.") }
        generationID = UUID()
        generation?.cancel()
        generation = nil
        isGenerating = false
        retrievalStatus = nil
    }

    func clearSession() {
        cancel()
        question = ""
        result = nil
        history = []
        lastQuestion = nil
        errorMessage = nil
        retrievalStatus = nil
    }

    func downloadModel(embedding: Bool) {
        guard download == nil else { return }
        let location = embedding ? configuration.embedding : configuration.llm
        let id = UUID()
        downloadID = id
        downloadingEmbedding = embedding
        retryDownloadEmbedding = nil
        downloadProgress = 0
        downloadStatus = analysisText("Downloading model files only from Hugging Face. Transcript text is never sent.")
        download = Task { [weak self] in
            do {
                try await MacAnalysisModelFiles.download(location, embedding: embedding) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard self?.downloadID == id else { return }
                        self?.downloadProgress = progress
                    }
                }
                guard let self, self.downloadID == id else { return }
                self.download = nil
                self.downloadProgress = nil
                self.downloadingEmbedding = nil
                self.downloadStatus = analysisText("Pinned model downloaded. Architecture and tokenizer compatibility are checked when first used.")
                await self.refreshAvailability()
            } catch {
                guard let self, self.downloadID == id else { return }
                self.download = nil
                self.downloadProgress = nil
                self.retryDownloadEmbedding = embedding
                self.downloadingEmbedding = nil
                self.downloadStatus = MacAnalysisEvidence.prefix(error.localizedDescription, bytes: 500)
            }
        }
    }

    func cancelDownload() {
        let wasDownloading = download != nil
        let target = downloadingEmbedding
        downloadID = UUID()
        download?.cancel()
        download = nil
        downloadProgress = nil
        downloadingEmbedding = nil
        if wasDownloading {
            retryDownloadEmbedding = target
            downloadStatus = analysisText("Download cancelled. Retry in Settings.")
        }
    }

    func retryDownload() {
        guard let embedding = retryDownloadEmbedding else { return }
        downloadModel(embedding: embedding)
    }

    func selectDirectory(_ url: URL, embedding: Bool) {
        do {
            var next = configuration
            if embedding { try next.embedding.selectDirectory(url) }
            else { try next.llm.selectDirectory(url) }
            configuration = next
        } catch { errorMessage = error.localizedDescription }
    }

    func dismissError() { errorMessage = nil }
}
