import Foundation
import Observation

@MainActor
@Observable
final class MacVoiceprintsModel {
    private(set) var profiles: [MacVoiceprintProfile] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
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
}
