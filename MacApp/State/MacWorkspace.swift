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
    let bonjour: MacBonjourService
    let processing = MacProcessingModel()
    let meetingCopy: MacMeetingCopyController
    @ObservationIgnored private var startupTask: Task<Void, Never>?
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
        #if DEBUG
        if let run = ProcessInfo.processInfo.environment["TRANSCRIPT_MAC_TEST_RUN_ID"],
           let id = UUID(uuidString: run) {
            let preferences = UserDefaults(suiteName: "TranscriptMacUITests-\(id.uuidString)")
            bonjour = MacBonjourService(
                serviceName: "Transcript Mac QA \(id.uuidString.prefix(8))",
                pairingStore: MacPairingKeychainStore(service: "com.transcript.mac.qa.\(id.uuidString)"),
                preferences: preferences
            )
            meetingCopy = MacMeetingCopyController(preferences: preferences)
        } else {
            bonjour = MacBonjourService()
            meetingCopy = MacMeetingCopyController()
        }
        #else
        bonjour = MacBonjourService()
        meetingCopy = MacMeetingCopyController()
        #endif
        if let library {
            self.library = library
            return
        }
        #if DEBUG
        if let runID = ProcessInfo.processInfo.environment["TRANSCRIPT_MAC_TEST_RUN_ID"],
           let id = UUID(uuidString: runID) {
            self.library = MacLibraryModel(directory: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
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

    func startServices() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           ProcessInfo.processInfo.environment["TRANSCRIPT_MAC_TEST_RUN_ID"] == nil { return }
        #endif
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task { [self] in
            await meetingCopy.prepare(library: library)
            let pairing = bonjour.pairing
            pairing.makeMeetingCopySession = { [weak pairing, weak meetingCopy] peer, identity in
                meetingCopy?.makeSession(peer: peer, receiverIdentity: identity) {
                    guard let pairing else { return false }
                    return try pairing.isConnectedAndTrusted(peer)
                }
            }
            bonjour.advertiseMeetingCopy(meetingCopy.canReceive)
            if ProcessInfo.processInfo.environment["TRANSCRIPT_MAC_TEST_RUN_ID"] == nil,
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                bonjour.restoreDiscovery()
            }
        }
        startupTask = task
        await task.value
    }

    func setMeetingCopyEnabled(_ enabled: Bool) {
        guard meetingCopy.isEnabled != enabled else { return }
        meetingCopy.setEnabled(enabled)
        // Capability acceptance belongs to a session; reconnect after permission changes.
        bonjour.pairing.disconnect()
        bonjour.advertiseMeetingCopy(meetingCopy.canReceive)
    }

    func retryMeetingCopyStorage() async {
        await meetingCopy.prepare(library: library)
        if bonjour.advertisesMeetingCopy != meetingCopy.canReceive {
            bonjour.pairing.disconnect()
        }
        bonjour.advertiseMeetingCopy(meetingCopy.canReceive)
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
