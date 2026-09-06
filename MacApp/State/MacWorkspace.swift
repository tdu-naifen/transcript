import Observation
import SwiftUI
import TranscriptCore

enum MacSection: String, CaseIterable, Identifiable {
    case meetings, processing, connection, voiceprints, analysis

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .meetings: "Meetings"
        case .processing: "Processing"
        case .connection: "Connection"
        case .voiceprints: "Voiceprints"
        case .analysis: "LLM Analysis"
        }
    }

    var symbol: String {
        switch self {
        case .meetings: "doc.text"
        case .processing: "clock"
        case .connection: "network"
        case .voiceprints: "person.wave.2"
        case .analysis: "text.bubble"
        }
    }
}

@MainActor @Observable
final class MacWorkspace {
    let library: MacLibraryModel
    let player = MacAudioPlayer()
    let bonjour = MacBonjourService()
    var section: MacSection? = .meetings
    var selectedMeetingID: String?
    var search = ""
    var showingSamples = false
    var showingImporter = false
    var importError: String?
    var referenceError: String?
    var referenceLocation: MacTranscriptLocation?
    var analysisMeetingID: String?

    init(library: MacLibraryModel? = nil) {
        if let library {
            self.library = library
            return
        }
        #if DEBUG
        if let runID = ProcessInfo.processInfo.environment["TRANSCRIPT_MAC_TEST_RUN_ID"],
           let id = UUID(uuidString: runID) {
            self.library = MacLibraryModel(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptMacUITests-\(id.uuidString)", isDirectory: true))
        } else {
            self.library = MacLibraryModel()
        }
        #else
        self.library = MacLibraryModel()
        #endif
    }

    var items: [MacLibraryItem] {
        showingSamples ? MacSampleLibrary.items : library.items
    }

    var filteredItems: [MacLibraryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.meeting.title.localizedStandardContains(query)
                || $0.utterances.contains { $0.text.localizedStandardContains(query) }
        }
    }

    var selectedItem: MacLibraryItem? {
        filteredItems.first { $0.id == selectedMeetingID }
    }

    func setSamples(_ enabled: Bool) {
        section = .meetings
        guard showingSamples != enabled else { return }
        player.unload()
        showingSamples = enabled
        search = ""
        selectedMeetingID = items.first?.id
    }

    func selectFirstIfNeeded() {
        if !filteredItems.contains(where: { $0.id == selectedMeetingID }) {
            selectedMeetingID = filteredItems.first?.id
        }
    }

    func openReference(meetingID: String, utteranceID: String) {
        guard let item = library.items.first(where: { $0.id == meetingID }),
              let utterance = item.utterances.first(where: { $0.id == utteranceID }) else {
            referenceError = String(localized: "This source is no longer available. Refresh the library and generate a new answer.")
            return
        }
        setSamples(false)
        search = ""
        selectedMeetingID = meetingID
        referenceLocation = MacTranscriptLocation(
            meetingID: meetingID, utteranceID: utteranceID,
            startSeconds: Double(utterance.startMs) / 1000
        )
    }
}

struct MacTranscriptLocation: Identifiable, Equatable {
    let id = UUID()
    let meetingID: String
    let utteranceID: String
    let startSeconds: TimeInterval
}
