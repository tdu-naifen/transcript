import Foundation
import Observation
import TranscriptCore

protocol MacModelDownloading: Sendable {
    func install(
        category: MacModelCategory,
        progress: @escaping @Sendable (ASRModelDownloadState) async -> Void
    ) async throws -> URL
    func cancel() async
}

actor MacCoreModelDownloader: MacModelDownloading {
    typealias Progress = @Sendable (ASRModelDownloadState) async -> Void
    typealias Fetch = @Sendable (MacModelCategory, URL, @escaping Progress) async throws -> Void
    typealias Verify = @Sendable (MacModelCategory, URL) async throws -> Void
    private let root: URL
    private let existingURLs: [MacModelCategory: URL]
    private let fetchOverride: Fetch?
    private let verify: Verify
    private var downloader: ASRModelDownloader?

    init(
        root: URL = MacManagedModelStore.root,
        existingURLs: [MacModelCategory: URL] = Dictionary(uniqueKeysWithValues:
            MacModelCategory.allCases.map { ($0, MacManagedModelStore.legacyURL($0)) }),
        fetch: Fetch? = nil,
        verify: @escaping Verify = { try await MacModelArtifactVerifier.verify(category: $0, at: $1) }
    ) {
        self.root = root
        self.existingURLs = existingURLs
        self.fetchOverride = fetch
        self.verify = verify
    }

    func install(
        category: MacModelCategory,
        progress: @escaping @Sendable (ASRModelDownloadState) async -> Void
    ) async throws -> URL {
        let adapter = MacModelCard.builtins.first { $0.category == category }!.adapter
        let destination = MacManagedModelStore.publishedURL(category, root: root)
        for candidate in [destination, existingURLs[category]].compactMap({ $0 }) {
            try Task.checkCancellation()
            guard !MacManagedModelStore.isRejected(candidate),
                  MacModelCard.hasCompatibleLayout(adapter: adapter, at: candidate) else { continue }
            await progress(.verifying)
            do {
                try await verify(category, candidate)
                try Task.checkCancellation()
                try MacManagedModelStore.record(category: category, at: candidate, rejected: false)
                return candidate
            } catch {
                if case MacModelArtifactVerifier.Failure.invalidFile = error {
                    try MacManagedModelStore.record(category: category, at: candidate, rejected: true)
                } else if !MacModelCard.hasCompatibleLayout(adapter: adapter, at: candidate) {
                    try MacManagedModelStore.record(category: category, at: candidate, rejected: true)
                }
                throw error
            }
        }

        let attempt = root.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        let payload = attempt.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: attempt) }
        if let fetchOverride {
            try await fetchOverride(category, payload, progress)
        } else {
            try await fetchCore(category: category, to: payload, progress: progress)
        }
        try Task.checkCancellation()
        await progress(.verifying)
        guard MacModelCard.hasCompatibleLayout(adapter: adapter, at: payload) else {
            throw MacProcessingError.missingModels
        }
        try await verify(category, payload)
        try Task.checkCancellation()
        try publish(payload, to: destination, category: category)
        return destination
    }

    private func fetchCore(category: MacModelCategory, to payload: URL, progress: @escaping Progress) async throws {
        let downloader = ASRModelDownloader(configuration: .init(
            destination: payload, sortformerDestination: payload, campPlusDestination: payload))
        self.downloader = downloader
        let stream = await downloader.states()
        let updates = Task {
            for await state in stream {
                guard !Task.isCancelled else { break }
                await progress(state)
            }
        }
        defer { updates.cancel(); self.downloader = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            switch category {
            case .asr: _ = try await downloader.ensureInstalled()
            case .diarization: _ = try await downloader.ensureSortformerInstalled()
            case .speakerEmbedding: _ = try await downloader.ensureCampPlusInstalled()
            }
        } onCancel: {
            Task { await downloader.cancel() }
        }
    }

    private func publish(_ payload: URL, to destination: URL, category: MacModelCategory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let hadPrevious = fm.fileExists(atPath: destination.path)
        let receipt = MacManagedModelStore.validationURL(destination)
        let previousReceipt = try? Data(contentsOf: receipt)
        if hadPrevious { try fm.moveItem(at: destination, to: backup) }
        do {
            // Keep the destination unavailable between the rename and verified receipt publication.
            try MacManagedModelStore.record(category: category, at: destination, rejected: true)
            try fm.moveItem(at: payload, to: destination)
            try MacManagedModelStore.record(category: category, at: destination, rejected: false)
            if hadPrevious { try? fm.removeItem(at: backup) }
        } catch {
            try? fm.removeItem(at: destination)
            if hadPrevious { try? fm.moveItem(at: backup, to: destination) }
            if let previousReceipt { try? previousReceipt.write(to: receipt, options: .atomic) }
            throw error
        }
    }

    func cancel() async { await downloader?.cancel() }
}

struct MacModelDownload: Identifiable, Equatable {
    enum Stage: String {
        case queued = "Queued"
        case downloading = "Downloading"
        case verifying = "Verifying model files"
        case installed = "Downloaded and validated"
        case failed = "Download failed"
        case cancelled = "Download cancelled"
    }
    let category: MacModelCategory
    var stage: Stage = .queued
    var fraction = 0.0
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var error: String?
    var id: String { category.rawValue }
}

@MainActor @Observable
final class MacProcessingModel {
    let catalog = MacModelCatalog()
    private(set) var jobs: [MacProcessingJob] = []
    private(set) var activeJobID: UUID?
    private(set) var isDownloading = false
    private(set) var downloadProgress = 0.0
    private(set) var downloads: [MacModelDownload] = []
    private(set) var isCancellingDownload = false
    private(set) var errorMessage: String?
    private(set) var isConfigured = false
    private(set) var isApplying = false
    @ObservationIgnored private var context: MacLibraryContext?
    @ObservationIgnored private var store: MacProcessingStore?
    @ObservationIgnored private let worker: MacProcessingWorker
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloader: (any MacModelDownloading)?
    @ObservationIgnored private var downloadAttemptID: UUID?
    @ObservationIgnored private let makeDownloader: @Sendable () -> any MacModelDownloading

    init(
        runner: any MacProcessingRunning = MacCoreProcessingRunner(),
        makeDownloader: @escaping @Sendable () -> any MacModelDownloading = { MacCoreModelDownloader() }
    ) {
        worker = MacProcessingWorker(runner: runner)
        self.makeDownloader = makeDownloader
    }

    var isBusy: Bool { activeJobID != nil || isDownloading || isApplying }
    var canRun: Bool {
        isConfigured && !isBusy && catalog.selected(.asr)?.adapter == .nemotronMultilingual
            && catalog.selected(.asr)?.isInstalled() == true
    }

    func configure(context: MacLibraryContext) {
        if self.context?.directory == context.directory, isConfigured { return }
        guard !isBusy else { report(MacProcessingError.alreadyRunning); return }
        do {
            let store = try MacProcessingStore(libraryDirectory: context.directory)
            try catalog.load(directory: context.directory)
            let restored = try store.load()
            self.context = context
            self.store = store
            jobs = restored
            downloads = []
            isConfigured = true
            errorMessage = nil
        } catch {
            self.context = nil
            self.store = nil
            isConfigured = false
            errorMessage = error.localizedDescription
        }
    }

    func report(_ error: any Error) { errorMessage = error.localizedDescription }
    func clearError() { errorMessage = nil }

    func start(meetingID: String) {
        guard !isBusy else { report(MacProcessingError.alreadyRunning); return }
        guard let context, let store, isConfigured else { report(MacProcessingError.notConfigured); return }
        guard let asr = catalog.selected(.asr), asr.adapter == .nemotronMultilingual else {
            report(MacProcessingError.unsupportedModel); return
        }
        let cards = [asr]
        guard ["auto", "en-US", "zh-CN"].contains(catalog.language) else {
            report(MacProcessingError.unsupportedModel); return
        }
        let job = MacProcessingJob(
            id: UUID(), meetingID: meetingID, createdAt: Date(), state: .preparing,
            stage: "Preparing frozen input", progress: 0, language: catalog.language, models: [])
        do {
            try catalog.save()
            try store.save(job)
        } catch { report(error); return }
        jobs.insert(job, at: 0)
        activeJobID = job.id
        errorMessage = nil
        activeTask = Task {
            defer {
                try? FileManager.default.removeItem(at: store.audio(job.id))
                activeJobID = nil
                activeTask = nil
            }
            do {
                var frozen = try await worker.prepare(job: job, cards: cards, context: context, store: store)
                try Task.checkCancellation()
                frozen.state = .running
                frozen.stage = "loadingAudio"
                try replace(frozen, store: store)
                let proposal = try await worker.process(job: frozen, context: context, store: store) { [weak self] update in
                    await self?.recordProgress(id: job.id, update: update)
                }
                try Task.checkCancellation()
                frozen.proposal = proposal
                frozen.state = .readyForReview
                frozen.stage = "Local ASR version ready for review"
                frozen.progress = 1
                try replace(frozen, store: store)
            } catch {
                guard var failed = jobs.first(where: { $0.id == job.id }) else { return }
                failed.state = Task.isCancelled ? .cancelled : .failed
                failed.error = Task.isCancelled ? processingText("Cancelled. The original transcript is unchanged.") : error.localizedDescription
                failed.stage = failed.state.rawValue
                do { try replace(failed, store: store) } catch { report(error) }
                if failed.state == .failed { errorMessage = failed.error }
            }
        }
    }

    func retry(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        // Retry creates a new immutable input version, never reuses a stale proposal.
        start(meetingID: job.meetingID)
    }

    func cancel() {
        guard let activeJobID, let store,
              var job = jobs.first(where: { $0.id == activeJobID }) else { return }
        job.state = .cancelling
        do { try replace(job, store: store) } catch { report(error) }
        activeTask?.cancel()
    }

    func keepLocalVersion(jobID: UUID) {
        guard !isBusy, let store,
              var job = jobs.first(where: { $0.id == jobID }),
              job.version == 2, job.state == .readyForReview, job.proposal != nil else { return }
        job.state = .savedLocally
        job.stage = "Kept as a local ASR version"
        do { try replace(job, store: store) } catch { report(error); return }
    }

    func useInLibrary(jobID: UUID) async -> Bool {
        guard !isBusy else { report(MacProcessingError.alreadyRunning); return false }
        guard let context, let job = jobs.first(where: { $0.id == jobID }) else {
            report(MacProcessingError.notConfigured); return false
        }
        isApplying = true
        defer { isApplying = false }
        do {
            try await MacLocalTranscriptAdoption.apply(job, context: context)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func installCompatibleModels(categories: [MacModelCategory] = MacModelCategory.allCases) {
        guard !isBusy else { report(MacProcessingError.alreadyRunning); return }
        guard isConfigured else { report(MacProcessingError.notConfigured); return }
        let categories = MacModelCategory.allCases.filter { categories.contains($0) }
        guard !categories.isEmpty else { report(MacProcessingError.unsupportedModel); return }
        isDownloading = true
        isCancellingDownload = false
        downloadProgress = 0
        downloads = categories.map { MacModelDownload(category: $0) }
        let attemptID = UUID()
        downloadAttemptID = attemptID
        errorMessage = nil
        downloadTask = Task {
            defer {
                isDownloading = false
                isCancellingDownload = false
                self.downloader = nil
                downloadAttemptID = nil
                downloadTask = nil
            }
            for category in categories {
                guard !Task.isCancelled else { break }
                let downloader = makeDownloader()
                self.downloader = downloader
                updateDownload(category) { $0.stage = .downloading }
                do {
                    let location = try await downloader.install(category: category) { [weak self] state in
                        await self?.recordDownloadProgress(category: category, state: state, attemptID: attemptID)
                    }
                    try Task.checkCancellation()
                    updateDownload(category) { $0.stage = .verifying }
                    try catalog.useManagedModel(category: category, at: location)
                    updateDownload(category) { $0.stage = .installed; $0.fraction = 1 }
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError
                    let message = cancelled ? processingText("Model download cancelled.") : error.localizedDescription
                    updateDownload(category) {
                        $0.stage = cancelled ? .cancelled : .failed
                        $0.error = message
                    }
                    errorMessage = message
                    if cancelled { break }
                }
            }
            if Task.isCancelled {
                for category in categories {
                    updateDownload(category) {
                        if $0.stage == .queued { $0.stage = .cancelled }
                    }
                }
            }
        }
    }

    func retryDownloads() {
        installCompatibleModels(categories: downloads.filter {
            $0.stage == .failed || $0.stage == .cancelled
        }.map(\.category))
    }

    func cancelDownload() {
        guard isDownloading, !isCancellingDownload else { return }
        isCancellingDownload = true
        downloadTask?.cancel()
        if let downloader { Task { await downloader.cancel() } }
    }

    func waitForDownloads() async { await downloadTask?.value }

    private func recordDownloadProgress(category: MacModelCategory, state: ASRModelDownloadState, attemptID: UUID) {
        guard downloadAttemptID == attemptID, !isCancellingDownload else { return }
        updateDownload(category) { download in
            guard [.downloading, .verifying].contains(download.stage) else { return }
            switch state {
            case .downloading(let completed, let total):
                download.stage = .downloading
                download.fraction = state.fraction
                download.completedBytes = completed
                download.totalBytes = total
            case .verifying, .installed:
                download.stage = .verifying
            case .notInstalled, .failed: break
            }
        }
    }

    private func updateDownload(_ category: MacModelCategory, change: (inout MacModelDownload) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.category == category }) else { return }
        change(&downloads[index])
        downloadProgress = downloads.reduce(0) { $0 + $1.fraction } / Double(max(1, downloads.count))
    }

    func waitForCurrentJob() async { await activeTask?.value }

    private func recordProgress(id: UUID, update: MeetingReprocessingProgress) {
        guard let store, var job = jobs.first(where: { $0.id == id }), job.state == .running else { return }
        job.stage = update.stage.rawValue
        job.progress = update.fractionCompleted
        do { try replace(job, store: store) } catch {
            report(error)
            activeTask?.cancel()
        }
    }

    private func replace(_ job: MacProcessingJob, store: MacProcessingStore) throws {
        try store.save(job)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
    }
}
