import Foundation
import Observation
import TranscriptCore

@MainActor @Observable
final class MacProcessingModel {
    let catalog = MacModelCatalog()
    private(set) var jobs: [MacProcessingJob] = []
    private(set) var activeJobID: UUID?
    private(set) var isDownloading = false
    private(set) var downloadProgress = 0.0
    private(set) var errorMessage: String?
    private(set) var isConfigured = false
    private(set) var isApplying = false
    @ObservationIgnored private var context: MacLibraryContext?
    @ObservationIgnored private var store: MacProcessingStore?
    @ObservationIgnored private let worker: MacProcessingWorker
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloader: ASRModelDownloader?

    init(runner: any MacProcessingRunning = MacCoreProcessingRunner()) {
        worker = MacProcessingWorker(runner: runner)
    }

    var isBusy: Bool { activeJobID != nil || isDownloading || isApplying }
    var canRun: Bool {
        isConfigured && !isBusy && catalog.selected(.asr)?.adapter == .nemotronMultilingual
            && catalog.selected(.asr)?.isInstalled() == true
    }

    func configure(context: MacLibraryContext) {
        guard !isBusy else { return }
        if self.context?.directory == context.directory, isConfigured { return }
        do {
            let store = try MacProcessingStore(libraryDirectory: context.directory)
            try catalog.load(directory: context.directory)
            let restored = try store.load()
            self.context = context
            self.store = store
            jobs = restored
            isConfigured = true
            errorMessage = nil
        } catch {
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

    func installCompatibleModels() {
        guard !isBusy, isConfigured else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        let downloader = ASRModelDownloader()
        self.downloader = downloader
        downloadTask = Task {
            let updates = Task {
                for await state in await downloader.states() {
                    guard !Task.isCancelled else { break }
                    downloadProgress = state.fraction
                }
            }
            defer {
                updates.cancel()
                isDownloading = false
                self.downloader = nil
                downloadTask = nil
            }
            do {
                let installation = try await downloader.ensureInstalled()
                try Task.checkCancellation()
                try catalog.useManagedASR(installation)
                downloadProgress = 1
            } catch {
                errorMessage = Task.isCancelled ? processingText("Model download cancelled.") : error.localizedDescription
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        if let downloader { Task { await downloader.cancel() } }
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
