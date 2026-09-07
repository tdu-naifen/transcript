import Foundation
import GRDB
import Observation
import TranscriptCore

@MainActor
@Observable
final class MacLibraryModel {
    private(set) var items: [MacLibraryItem] = []
    private(set) var isLoading = false
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private(set) var revision = 0

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var storeTask: Task<MacLibraryStore, any Error>?
    @ObservationIgnored private var storeGeneration = 0
    @ObservationIgnored private var audioFiles: AudioFileStore?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var databaseRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsDatabaseRefresh = false

    init(directory: URL? = nil) {
        self.directory = directory
        storeTask = Task.detached(priority: .userInitiated) {
            try MacLibraryStore(directory: directory)
        }
    }

    func load() async {
        await refresh(clearError: true)
    }

    private func refresh(clearError: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
                scheduleDatabaseRefresh()
            }
        }
        do {
            let store = try await readyStore()
            let loaded = try await store.load()
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            items = loaded
            revision &+= 1
            if clearError { errorMessage = nil }
        } catch is CancellationError {
            return
        } catch {
            if generation == loadGeneration { errorMessage = error.localizedDescription }
        }
    }

    func importAudio(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            let store = try await readyStore()
            _ = try await store.importAudio(from: url)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(id: String, title: String) async {
        errorMessage = nil
        do {
            let store = try await readyStore()
            try await store.rename(id: id, title: title)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func processingContext() async throws -> MacLibraryContext {
        try await readyStore().context
    }

    func voiceprints() async throws -> [MacVoiceprintProfile] {
        let store = try await readyStore()
        return try await store.voiceprints()
    }

    func audioURL(for item: MacLibraryItem) throws -> URL {
        guard let audioFiles, let name = item.meeting.audioFileName,
              audioFiles.exists(fileName: name) else { throw MacLibraryError.audioUnavailable }
        return try audioFiles.url(forFileName: name)
    }

    private func readyStore() async throws -> MacLibraryStore {
        let task: Task<MacLibraryStore, any Error>
        if let storeTask {
            task = storeTask
        } else {
            let directory = directory
            storeGeneration += 1
            task = Task.detached(priority: .userInitiated) {
                try MacLibraryStore(directory: directory)
            }
            storeTask = task
        }
        let generation = storeGeneration
        do {
            let store = try await task.value
            audioFiles = store.audioFiles
            observe(database: store.context.database)
            return store
        } catch {
            // An older failed waiter must not discard an initialization already retried.
            if generation == storeGeneration { storeTask = nil }
            throw error
        }
    }

    private func observe(database: AppDatabase) {
        guard observation == nil else { return }
        observation = DatabaseRegionObservation(
            tracking: Meeting.all(), Speaker.all(), MeetingSpeaker.all(), Utterance.all()
        ).start(in: database.writer) { [weak self] error in
            Task { @MainActor [weak self] in self?.errorMessage = error.localizedDescription }
        } onChange: { [weak self] _ in
            Task { @MainActor [weak self] in self?.databaseDidChange() }
        }
    }

    private func databaseDidChange() {
        needsDatabaseRefresh = true
        scheduleDatabaseRefresh()
    }

    private func scheduleDatabaseRefresh() {
        guard needsDatabaseRefresh, !isLoading, databaseRefreshTask == nil else { return }
        databaseRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                databaseRefreshTask = nil
                scheduleDatabaseRefresh()
            }
            while needsDatabaseRefresh && !isLoading && !Task.isCancelled {
                needsDatabaseRefresh = false
                await refresh(clearError: false)
            }
        }
    }

    isolated deinit {
        observation?.cancel()
        databaseRefreshTask?.cancel()
    }
}
