import Observation
import OSLog
import SwiftUI
import TranscriptCore

enum MacSection: String, CaseIterable, Identifiable {
    case meetings, voiceprints, analysis

    static let allCases: [MacSection] = [.meetings, .voiceprints]

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .meetings: "Meetings"
        case .voiceprints: "Voiceprints"
        case .analysis: "LLM Analysis"
        }
    }

    var symbol: String {
        switch self {
        case .meetings: "doc.text"
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
    let analysis = MacAnalysisModel()
    let meetingCopy: MacMeetingCopyController
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    var section: MacSection? = .meetings
    var selectedMeetingID: String?
    var search = ""
    var showingSamples = false
    var showingImporter = false
    var showingConnection = false
    var importError: String?
    var referenceError: String?
    var referenceLocation: MacTranscriptLocation?
    var analysisMeetingID: String?

    #if DEBUG
    private static let testRunID: UUID? = {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["TRANSCRIPT_MAC_TEST_RUN_ID"] {
            if let id = UUID(uuidString: value) { return id }
            Logger(subsystem: "com.transcript.mac", category: "TestIsolation")
                .error("Invalid test namespace; refusing to use production storage.")
            return UUID()
        }
        let isTesting = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
        return isTesting ? UUID() : nil
    }()
    #endif

    init(library: MacLibraryModel? = nil) {
        #if DEBUG
        if let id = Self.testRunID {
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
        if let id = Self.testRunID {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TranscriptMacUITests-\(id.uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                setenv("TRANSCRIPT_TEST_ROOT", root.path, 1)
            } catch {
                fatalError("Unable to create isolated Mac test storage: \(error)")
            }
            self.library = MacLibraryModel(directory: root.appendingPathComponent("Library", isDirectory: true))
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
            do {
                let context = try await library.processingContext()
                processing.replayAutomaticImports = { [weak pairing = bonjour.pairing] in
                    try await pairing?.replayAutomaticAudioImports()
                }
                processing.configure(context: context)
                bonjour.pairing.installAutomaticSync(
                    database: context.database, audioDirectory: context.audioFiles.directory,
                    onAudioImported: { [weak processing] imported in
                        await processing?.enqueueImportedMeeting(
                            meetingID: imported.meetingID, inputRevision: imported.inputRevision,
                            provenance: .init(peerID: imported.peerID, operationID: imported.operationID)
                        )
                    }
                )
                bonjour.advertiseAutomaticSync(true)
                try await AutomaticSyncRepository(context.database).collectRevokedFiles()
                try await bonjour.pairing.replayAutomaticAudioImports()
            } catch { processing.report(error) }
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
        startupTask = nil
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
            player.unload()
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
