import Foundation
import Observation
import TranscriptCore

@MainActor
@Observable
final class LibraryModel {
    private(set) var meetings: [Meeting] = []
    /// `Speaker.colorIndex` per meeting, in `displayIndex` order, for the recordings-list
    /// color dots (UI.md §4.4 — color is stable across meetings, name is not).
    private(set) var speakerColorIndexes: [String: [Int]] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let repository: MeetingRepository
    private let speakerRepository: SpeakerRepository
    private let store: AudioFileStore
    let database: AppDatabase

    init(services: AppServices) {
        repository = MeetingRepository(services.database)
        speakerRepository = SpeakerRepository(services.database)
        store = services.store
        database = services.database
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await repository.fetchAll()
            var colors: [String: [Int]] = [:]
            for meeting in fetched {
                let speakers = try await speakerRepository.speakers(inMeeting: meeting.id)
                colors[meeting.id] = speakers.map(\.speaker.colorIndex)
            }
            meetings = fetched
            speakerColorIndexes = colors
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func audioURL(for meeting: Meeting) -> URL? {
        guard let fileName = meeting.audioFileName else { return nil }
        return try? store.url(forFileName: fileName)
    }

    /// Removes both the DB row and the audio file on disk (PLAN §9.4.1: previously only
    /// the row was ever removed, leaking the file).
    func delete(_ meeting: Meeting) async {
        if let fileName = meeting.audioFileName {
            try? store.remove(fileName: fileName)
        }
        do {
            try await repository.delete(id: meeting.id)
            meetings.removeAll { $0.id == meeting.id }
            speakerColorIndexes.removeValue(forKey: meeting.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
