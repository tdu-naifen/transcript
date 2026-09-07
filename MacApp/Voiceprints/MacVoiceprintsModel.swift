import Foundation
import Observation
import GRDB
import TranscriptCore

@MainActor
@Observable
final class MacVoiceprintsModel {
    private(set) var profiles: [MacVoiceprintProfile] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var editError: String?
    private(set) var isSaving = false
    var search = ""
    var selectedID: String?
    @ObservationIgnored private var loadGeneration = 0

    var filteredProfiles: [MacVoiceprintProfile] {
        profiles.filter { $0.matches(search) }
    }

    var selectedProfile: MacVoiceprintProfile? {
        filteredProfiles.first { $0.id == selectedID } ?? filteredProfiles.first
    }

    func load(using loader: @MainActor () async throws -> [MacVoiceprintProfile]) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let loaded = try await loader()
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            profiles = loaded
            errorMessage = nil
            selectedID = selectedProfile?.id
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func observe(context: MacLibraryContext) async {
        isLoading = profiles.isEmpty
        let observation = ValueObservation.tracking { db in try Self.readProfiles(db) }
        do {
            for try await loaded in observation.values(in: context.database.reader) {
                try Task.checkCancellation()
                loadGeneration += 1
                profiles = loaded
                selectedID = selectedProfile?.id
                errorMessage = nil
                isLoading = false
            }
        } catch is CancellationError {
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func clearEditError() { editError = nil }

    func rename(id: String, displayName: String, context: MacLibraryContext) async -> Bool {
        guard !isSaving else { return false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 200 else {
            editError = String(localized: "Use a speaker name of 200 characters or fewer.")
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await SpeakerRepository(context.database).rename(
                id: id, displayName: name.isEmpty ? nil : name, deviceId: context.deviceID)
            let loaded = try await context.database.reader.read { db in try Self.readProfiles(db) }
            loadGeneration += 1
            profiles = loaded
            selectedID = selectedProfile?.id
            editError = nil
            return true
        } catch {
            editError = String(localized: "Unable to rename this speaker. Refresh the library and try again.")
            return false
        }
    }

    nonisolated private static func readProfiles(_ db: Database) throws -> [MacVoiceprintProfile] {
        let speakers = try Speaker.fetchAll(db)
        let embeddings = try SpeakerEmbedding.fetchAll(db)
        let grouped = Dictionary(grouping: embeddings, by: \.speakerId)
        return speakers.map { speaker in
            MacVoiceprintProfile(speaker: speaker, embeddings: (grouped[speaker.id] ?? []).sorted {
                $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
            })
        }.sorted {
            let order = $0.speaker.resolvedName.localizedStandardCompare($1.speaker.resolvedName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
