import Foundation
import Observation
import TranscriptCore

@MainActor
@Observable
final class LibraryModel {
    private(set) var meetings: [Meeting] = []
    /// Persisted speaker identity supplies both the current name and stable color.
    private(set) var participants: [String: [Speaker]] = [:]
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var deletingIDs: Set<String> = []
    private(set) var errorMessage: String?
    private(set) var errorTitleKey = "library.load_failed"

    var speakerColorIndexes: [String: [Int]] {
        participants.mapValues { $0.map(\.colorIndex) }
    }

    var availableSpeakers: [Speaker] {
        var byID: [String: Speaker] = [:]
        for speaker in participants.values.joined() { byID[speaker.id] = speaker }
        return byID.values.sorted {
            let order = $0.resolvedName.localizedStandardCompare($1.resolvedName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private let repository: MeetingRepository
    private let searchRepository: SearchRepository
    private let speakerRepository: SpeakerRepository
    private let store: AudioFileStore
    private var reloadID = UUID()
    private(set) var nextCursor: SearchCursor?
    let database: AppDatabase

    init(services: AppServices) {
        repository = MeetingRepository(services.database)
        searchRepository = SearchRepository(services.database)
        speakerRepository = SpeakerRepository(services.database)
        store = services.store
        database = services.database
    }

    func reload() async {
        let requestID = UUID()
        reloadID = requestID
        isLoading = true
        defer { if reloadID == requestID { isLoading = false } }
        do {
            let page = try await searchRepository.search(SearchQuery(limit: 25))
            let fetched = page.results.map(\.meeting)
            let speakersByMeeting = Dictionary(uniqueKeysWithValues: page.results.map {
                ($0.meeting.id, $0.participants.map(\.speaker))
            })
            try Task.checkCancellation()
            guard reloadID == requestID else { return }
            meetings = fetched.sorted {
                $0.startedAt == $1.startedAt ? $0.id > $1.id : $0.startedAt > $1.startedAt
            }
            participants = speakersByMeeting
            nextCursor = page.nextCursor
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
            // Leaving a screen is not a failed database load.
        } catch {
            guard reloadID == requestID else { return }
            errorTitleKey = "library.load_failed"
            errorMessage = error.localizedDescription
        }

    }

    func loadMore() async {
            guard !isLoading, let cursor = nextCursor else { return }
            let requestID = UUID()
            reloadID = requestID
            isLoading = true
            defer { if reloadID == requestID { isLoading = false } }
            do {
                let page = try await searchRepository.search(SearchQuery(limit: 25, cursor: cursor))
                try Task.checkCancellation()
                guard reloadID == requestID else { return }
                meetings.append(contentsOf: page.results.map(\.meeting))
                for result in page.results {
                    participants[result.meeting.id] = result.participants.map(\.speaker)
                }
                nextCursor = page.nextCursor
                hasLoaded = true
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                guard reloadID == requestID else { return }
                errorTitleKey = "library.load_failed"
                errorMessage = error.localizedDescription
        }
    }

    func audioURL(for meeting: Meeting) -> URL? {
        guard let fileName = meeting.audioFileName else { return nil }
        return try? store.url(forFileName: fileName)
    }

    /// Existing local deletion only. Never emits a cross-device delete or purges
    /// audio independently of the meeting. Keep audio intact if the DB delete fails.
    func delete(_ meeting: Meeting) async {
        guard deletingIDs.insert(meeting.id).inserted else { return }
        defer { deletingIDs.remove(meeting.id) }
        do {
            try await repository.delete(id: meeting.id)
        } catch {
            errorTitleKey = "library.delete_failed"
            errorMessage = error.localizedDescription
            return
        }
        // An older snapshot must not resurrect the deleted row in either tab.
        reloadID = UUID()
        isLoading = false
        meetings.removeAll { $0.id == meeting.id }
        participants.removeValue(forKey: meeting.id)
        errorMessage = nil
        do {
            if let fileName = meeting.audioFileName { try store.remove(fileName: fileName) }
        } catch {
            errorTitleKey = "library.audio_cleanup_failed"
            errorMessage = error.localizedDescription
        }
    }
}
