import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class MacMeetingCopyController {
    private(set) var isEnabled: Bool
    private(set) var isReady = false
    private(set) var isPreparing = false
    private(set) var progress: MacMeetingCopySession.Progress?
    private(set) var lastReceipt: MacMeetingCopyInbox.Receipt?
    private(set) var errorMessage: String?

    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private var inbox: MacMeetingCopyInbox?
    @ObservationIgnored private var currentSessionID: UUID?
    @ObservationIgnored private var preparation: Task<MacMeetingCopyInbox, any Error>?
    @ObservationIgnored private weak var library: MacLibraryModel?
    private let logger = Logger(subsystem: "com.transcript.mac", category: "MeetingCopy")
    private static let enabledKey = "mac.connection.receiveMeetingCopies"

    init(preferences: UserDefaults? = .standard) {
        self.preferences = preferences
        isEnabled = preferences?.bool(forKey: Self.enabledKey) ?? false
    }

    var canReceive: Bool { isEnabled && isReady }

    func prepare(library: MacLibraryModel) async {
        self.library = library
        guard !isReady else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            let task: Task<MacMeetingCopyInbox, any Error>
            if let preparation {
                task = preparation
            } else {
                let context = try await library.processingContext()
                task = Task.detached { try MacMeetingCopyInbox(context: context) }
                preparation = task
            }
            inbox = try await task.value
            isReady = true
            errorMessage = nil
        } catch {
            preparation = nil
            errorMessage = String.localizedStringWithFormat(
                String(localized: "Meeting receiving storage could not be opened: %@"), error.localizedDescription
            )
            logger.error("Meeting receiving storage initialization failed.")
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        preferences?.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            currentSessionID = nil
            progress = nil
        }
    }

    func makeSession(
        peer: MacPairedDevice,
        receiverIdentity: Data,
        isTrusted: @escaping @MainActor () throws -> Bool
    ) -> MacMeetingCopySession? {
        guard canReceive, let inbox else { return nil }
        let id = UUID()
        currentSessionID = id
        return MacMeetingCopySession(
            inbox: inbox, peerIdentity: peer.publicKey, receiverIdentity: receiverIdentity,
            isAuthorized: { [weak self] in
                guard let self, self.canReceive, self.currentSessionID == id else { return false }
                return try isTrusted()
            },
            onProgress: { [weak self] progress in
                guard let self, self.currentSessionID == id else { return }
                self.progress = progress
                if progress != nil { self.errorMessage = nil }
            },
            onCommit: { [weak self] receipt in
                guard let self, self.currentSessionID == id else { return }
                self.lastReceipt = receipt
                await self.library?.load()
                if let error = self.library?.errorMessage {
                    self.errorMessage = error
                }
            },
            onFailure: { [weak self] failure in
                guard let self, self.currentSessionID == id else { return }
                self.errorMessage = Self.message(for: failure)
                self.progress = nil
            }
        )
    }

    static func message(for failure: MeetingCopyWire.Failure) -> String {
        switch failure {
        case .storage:
            String(localized: "The copy could not be stored. Check free disk space and the receiving limits, then retry.")
        case .conflict:
            String(localized: "This meeting already exists or was deleted on this Mac. Nothing was overwritten.")
        case .invalid, .staleSnapshot:
            String(localized: "The meeting copy failed validation. No new copy was confirmed.")
        case .cancelled:
            String(localized: "Receiving was stopped. Your original iPhone audio is unchanged.")
        case .busy:
            String(localized: "Another meeting copy is being received. Wait for it to finish, then retry.")
        case .incompatible:
            String(localized: "This connection does not support this meeting-copy protocol.")
        }
    }
}
