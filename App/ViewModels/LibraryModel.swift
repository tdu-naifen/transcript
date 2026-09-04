import Foundation
import Observation
import TranscriptCore

@MainActor
@Observable
final class LibraryModel {
    private(set) var meetings: [Meeting] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let repository: MeetingRepository
    private let store: AudioFileStore

    init(services: AppServices) {
        repository = MeetingRepository(services.database)
        store = services.store
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            meetings = try await repository.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func audioURL(for meeting: Meeting) -> URL? {
        guard let fileName = meeting.audioFileName else { return nil }
        return try? store.url(forFileName: fileName)
    }
}
