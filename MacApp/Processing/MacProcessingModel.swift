import Foundation
import CryptoKit
import GRDB
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
    @ObservationIgnored private var invalidatedJobIDs: Set<UUID> = []
    @ObservationIgnored private var isReconcilingDeletedJobs = false
    @ObservationIgnored private var importObservation: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloader: (any MacModelDownloading)?
    @ObservationIgnored private var downloadAttemptID: UUID?
    @ObservationIgnored var onPublished: (@MainActor (String) async -> Void)?
    @ObservationIgnored var replayAutomaticImports: (@MainActor () async throws -> Void)?
    @ObservationIgnored private let makeDownloader: @Sendable () -> any MacModelDownloading

    init(
        runner: any MacProcessingRunning = MacCoreProcessingRunner(),
        makeDownloader: @escaping @Sendable () -> any MacModelDownloading = { MacCoreModelDownloader() }
    ) {
        worker = MacProcessingWorker(runner: runner)
        self.makeDownloader = makeDownloader
    }

    var isBusy: Bool { activeJobID != nil || isDownloading || isApplying || isReconcilingDeletedJobs }
    var canRun: Bool {
        resourcesReady && !isBusy
    }

    private var resourcesReady: Bool {
        isConfigured && ["auto", "en-US", "zh-CN"].contains(catalog.language)
            && catalog.selected(.asr)?.adapter == .nemotronMultilingual
            && catalog.selected(.diarization)?.adapter == .sortformer
            && catalog.selected(.speakerEmbedding)?.adapter == .campPlus
            && MacModelCategory.allCases.allSatisfy { catalog.selected($0)?.isInstalled() == true }
    }

    var configurationID: String {
        let fields = [catalog.language] + MacModelCategory.allCases.flatMap { category in
            let card = catalog.selected(category)
            return [card?.id ?? "", card?.revision ?? "", card?.adapter.rawValue ?? "",
                    card?.localPath ?? "", card?.bookmark?.base64EncodedString() ?? ""]
        }
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func configure(context: MacLibraryContext) {
        if self.context?.directory == context.directory, isConfigured { return }
        guard !isBusy else { report(MacProcessingError.alreadyRunning); return }
        do {
            let store = try MacProcessingStore(libraryDirectory: context.directory)
            try catalog.load(directory: context.directory)
            let existingMeetingIDs = try Self.meetingIDs(in: context)
            let restored = try store.load(existingMeetingIDs: existingMeetingIDs)
            self.context = context
            self.store = store
            jobs = restored
            invalidatedJobIDs = []
            downloads = []
            isConfigured = true
            errorMessage = nil
            resumeQueuedJobs()
            observeAutomaticImports(context: context)
        } catch {
            self.context = nil
            self.store = nil
            isConfigured = false
            errorMessage = error.localizedDescription
        }
    }

    func report(_ error: any Error) { errorMessage = error.localizedDescription }
    func clearError() { errorMessage = nil }

    func replayVerifiedImports() async {
        guard isConfigured else { return }
        do {
            // The pairing adapter rechecks current trust and sync authorization.
            try await replayAutomaticImports?()
        } catch { report(error) }
    }

    private func observeAutomaticImports(context: MacLibraryContext) {
        importObservation?.cancel()
        importObservation = Task { [weak self] in
            do {
                // Audio adoption commits a meeting update. The initial observation also
                // closes the crash gap between that commit and the separate job manifest.
                let observation = ValueObservation.tracking { db in try Meeting.fetchAll(db) }
                for try await _ in observation.values(in: context.database.reader) {
                    try Task.checkCancellation()
                    guard let self else { return }
                    do { try await self.reconcileDeletedMeetingJobs() } catch { self.report(error) }
                    await self.replayVerifiedImports()
                }
            } catch is CancellationError {
                return
            } catch {
                self?.report(error)
            }
        }
    }

    deinit { importObservation?.cancel() }

    private func reconcileDeletedMeetingJobs() async throws {
        guard let context, let store, !isReconcilingDeletedJobs else { return }
        let existing = try Self.meetingIDs(in: context)
        let orphans = jobs.filter { !existing.contains($0.meetingID) }
        guard !orphans.isEmpty else { return }
        isReconcilingDeletedJobs = true
        defer {
            isReconcilingDeletedJobs = false
            resumeQueuedJobs()
        }
        invalidatedJobIDs.formUnion(orphans.map(\.id))
        if let activeJobID, invalidatedJobIDs.contains(activeJobID), let task = activeTask {
            task.cancel()
            // A cancelled inference task can still be draining audio/model work.
            // Fence manifest writes now; remove its directory only after that task exits.
            await task.value
        }
        for job in orphans {
            try store.remove(job)
            jobs.removeAll { $0.id == job.id }
        }
    }

    private func requireMeeting(_ meetingID: String) throws {
        guard let context else { throw MacProcessingError.notConfigured }
        let exists = try context.database.reader.read { db in try Meeting.exists(db, key: meetingID) }
        guard exists else { throw MacProcessingError.missingMeeting }
    }

    private static func meetingIDs(in context: MacLibraryContext) throws -> Set<String> {
        try context.database.reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM meeting"))
        }
    }

    /// The authorized automatic-sync importer calls this only after verified audio commits.
    /// Legacy immutable-copy receipts and metadata/resource descriptors are not qualifying imports.
    func enqueueImportedMeeting(
        meetingID: String, inputRevision: String, provenance: MacProcessingImportProvenance
    ) async {
        guard !inputRevision.isEmpty, !provenance.peerID.isEmpty, !provenance.operationID.isEmpty,
              let store, isConfigured else {
            report(MacProcessingError.notConfigured); return
        }
        if jobs.contains(where: {
            $0.meetingID == meetingID && $0.inputRevision == inputRevision
                && ($0.automaticImport == provenance || $0.configurationID == configurationID
                    || [.queued, .waitingForConfiguration].contains($0.state))
        }) { return }
        let job = MacProcessingJob(
            id: UUID(), meetingID: meetingID, createdAt: Date(),
            state: resourcesReady ? .queued : .waitingForConfiguration,
            stage: resourcesReady ? "Queued" : "Waiting for configuration in Settings",
            progress: 0, language: catalog.language, models: [],
            inputRevision: inputRevision, configurationID: configurationID, automaticImport: provenance,
            destination: .library)
        do {
            try requireMeeting(meetingID)
            try store.save(job)
            jobs.insert(job, at: 0)
            resumeQueuedJobs()
        } catch { report(error) }
    }

    func resumeQueuedJobs() {
        guard !isBusy, let store else { return }
        if let job = jobs.reversed().first(where: {
            !invalidatedJobIDs.contains($0.id) && $0.state == .publishing && $0.destination == .library
        }) {
            resumePublication(job: job)
            return
        }
        for var job in jobs.reversed() where !invalidatedJobIDs.contains(job.id)
            && [.queued, .waitingForConfiguration].contains(job.state) {
            job.state = resourcesReady ? .queued : .waitingForConfiguration
            job.stage = resourcesReady ? "Queued" : "Waiting for configuration in Settings"
            // An unstarted request uses the configuration the user finishes setting up.
            job.configurationID = configurationID
            job.language = catalog.language
            do { try replace(job, store: store) } catch { report(error); return }
            if resourcesReady { execute(job: job); return }
        }
    }

    func start(meetingID: String, destination: MacProcessingJob.Destination = .library) {
        guard !isBusy else { report(MacProcessingError.alreadyRunning); return }
        guard context != nil, let store, isConfigured else { report(MacProcessingError.notConfigured); return }
        if jobs.contains(where: {
            $0.meetingID == meetingID && [.queued, .waitingForConfiguration].contains($0.state)
        }) {
            resumeQueuedJobs()
            return
        }
        guard let asr = catalog.selected(.asr), asr.adapter == .nemotronMultilingual else {
            report(MacProcessingError.unsupportedModel); return
        }
        guard ["auto", "en-US", "zh-CN"].contains(catalog.language) else {
            report(MacProcessingError.unsupportedModel); return
        }
        let job = MacProcessingJob(
            id: UUID(), meetingID: meetingID, createdAt: Date(),
            state: resourcesReady ? .preparing : .waitingForConfiguration,
            stage: resourcesReady ? "Preparing frozen input" : "Waiting for configuration in Settings",
            progress: 0, language: catalog.language, models: [], configurationID: configurationID,
            destination: destination)
        do {
            try requireMeeting(meetingID)
            try catalog.save()
            try store.save(job)
        } catch { report(error); return }
        jobs.insert(job, at: 0)
        errorMessage = nil
        if resourcesReady { execute(job: job) }
    }

    private func execute(job: MacProcessingJob) {
        guard let context, let store, resourcesReady else { return }
        let cards = MacModelCategory.allCases.compactMap { catalog.selected($0) }
        activeJobID = job.id
        errorMessage = nil
        activeTask = Task {
            defer {
                try? FileManager.default.removeItem(at: store.audio(job.id))
                activeJobID = nil
                activeTask = nil
                resumeQueuedJobs()
            }
            do {
                var preparing = job
                preparing.state = .preparing
                preparing.stage = "Preparing frozen input"
                try replace(preparing, store: store)
                var frozen = try await worker.prepare(job: preparing, cards: cards, context: context, store: store)
                try Task.checkCancellation()
                frozen.state = .running
                frozen.stage = "loadingAudio"
                try replace(frozen, store: store)
                let proposal = try await worker.process(job: frozen, context: context, store: store) { [weak self] update in
                    await self?.recordProgress(id: job.id, update: update)
                }
                try Task.checkCancellation()
                frozen.proposal = proposal
                frozen.state = frozen.destination == .library ? .publishing : .readyForReview
                frozen.stage = frozen.destination == .library ? "Publishing timed transcript" : "Local ASR version ready for review"
                frozen.progress = 1
                try replace(frozen, store: store)
                if frozen.destination == .library { try await publish(frozen, context: context, store: store) }
            } catch {
                guard !invalidatedJobIDs.contains(job.id) else { return }
                guard var failed = jobs.first(where: { $0.id == job.id }) else { return }
                failed.state = error as? AutomaticSyncWire.Failure == .staleRevision
                    ? .stale : (Task.isCancelled ? .cancelled : .failed)
                failed.error = Task.isCancelled ? processingText("Cancelled. The original transcript is unchanged.") : Self.jobErrorMessage(error)
                failed.stage = failed.state.rawValue
                do { try replace(failed, store: store) } catch { report(error) }
                if failed.state == .failed { errorMessage = failed.error }
            }
        }
    }

    func retry(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        if job.destination == .library, job.proposal != nil, job.state != .stale {
            guard !isBusy, let store else { return }
            var publishing = job
            publishing.state = .publishing
            publishing.stage = "Publishing timed transcript"
            publishing.error = nil
            do { try replace(publishing, store: store) } catch { report(error); return }
            resumePublication(job: publishing)
            return
        }
        // Retry creates a new immutable input version, never reuses a stale proposal.
        start(meetingID: job.meetingID, destination: job.destination ?? .localVersion)
    }

    private func publish(_ job: MacProcessingJob, context: MacLibraryContext, store: MacProcessingStore) async throws {
        let revision = try await MacAutomaticTranscriptPublication.apply(job, context: context)
        var published = job
        published.state = .published
        published.stage = "Timed transcript published in library"
        published.outputTranscriptRevision = revision
        published.publishedAt = Date()
        published.error = nil
        try replace(published, store: store)
        await onPublished?(job.meetingID)
    }

    private func resumePublication(job: MacProcessingJob) {
        guard let context, let store else { return }
        activeJobID = job.id
        activeTask = Task {
            defer {
                activeJobID = nil
                activeTask = nil
                resumeQueuedJobs()
            }
            do {
                try await publish(job, context: context, store: store)
            } catch {
                guard !invalidatedJobIDs.contains(job.id) else { return }
                var failed = job
                failed.state = error as? AutomaticSyncWire.Failure == .staleRevision ? .stale : .failed
                failed.error = Self.jobErrorMessage(error)
                failed.stage = failed.state.rawValue
                do { try replace(failed, store: store) } catch { report(error) }
            }
        }
    }

    private static func jobErrorMessage(_ error: any Error) -> String {
        guard let failure = error as? AutomaticSyncWire.Failure else { return error.localizedDescription }
        if failure == .staleRevision {
            return processingText("The transcript changed while processing. This result was retained but cannot overwrite newer edits. Reprocess to use the current version.")
        }
        return processingText("Unable to publish the transcript. No newer edits were overwritten. Retry publication from the meeting.")
    }

    func cancel(jobID: UUID) {
        guard let store, var job = jobs.first(where: { $0.id == jobID }) else { return }
        if job.id == activeJobID { cancel(); return }
        guard [.queued, .waitingForConfiguration].contains(job.state) else { return }
        job.state = .cancelled
        job.stage = "Cancelled"
        do { try replace(job, store: store) } catch { report(error) }
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
        defer {
            isApplying = false
            resumeQueuedJobs()
        }
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
                resumeQueuedJobs()
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

    func waitForCurrentJob() async {
        while let task = activeTask { await task.value }
    }

    private func recordProgress(id: UUID, update: MeetingReprocessingProgress) {
        guard !invalidatedJobIDs.contains(id), let store,
              var job = jobs.first(where: { $0.id == id }), job.state == .running else { return }
        job.stage = update.stage.rawValue
        job.progress = update.fractionCompleted
        do { try replace(job, store: store) } catch {
            report(error)
            activeTask?.cancel()
        }
    }

    private func replace(_ job: MacProcessingJob, store: MacProcessingStore) throws {
        guard !invalidatedJobIDs.contains(job.id) else { throw MacProcessingError.missingMeeting }
        try store.save(job)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
    }
}
