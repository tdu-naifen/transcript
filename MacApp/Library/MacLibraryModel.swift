import Foundation
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

    init(directory: URL? = nil) {
        self.directory = directory
        storeTask = Task.detached(priority: .userInitiated) {
            try MacLibraryStore(directory: directory)
        }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let store = try await readyStore()
            let loaded = try await store.load()
            guard generation == loadGeneration else { return }
            items = loaded
            revision &+= 1
            errorMessage = nil
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
            let item = try await store.importAudio(from: url)
            loadGeneration += 1
            items.insert(item, at: 0)
            revision &+= 1
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
            return store
        } catch {
            // An older failed waiter must not discard an initialization already retried.
            if generation == storeGeneration { storeTask = nil }
            throw error
        }
    }
}
