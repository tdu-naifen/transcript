import Foundation
import Observation

/// App presentation only. A long-lived service must publish verified snapshots and
/// own discovery, pairing, durable outbox work, receipts, and cancellation requests.
@MainActor
@Observable
final class MacConnectionModel {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    struct Pairing: Equatable {
        let device: Device
        let code: String
        let confirmedOnPhone: Bool
        let confirmedOnMac: Bool
    }

    enum Connection: Equatable {
        case unavailable
        case unpaired
        case discovering
        case pairing(Pairing)
        case offline(Device)
        case connecting(Device?)
        /// Publish only after identity verification and an available transport.
        /// Model readiness is independent of connection availability.
        case connected(Device, modelReady: Bool?)
        /// The adapter supplies an already-localized, actionable explanation.
        case failed(reason: String)
    }

    struct Job: Identifiable, Equatable {
        enum Phase: Equatable {
            case queuedLocally
            case sending
            case awaitingReconnect
            /// Requires the Mac's durable receipt, not a completed socket write.
            case receivedDurably
            case processing
            case resultsSynced
            case failed(reason: String)
        }

        enum Cancellation: Equatable {
            case none
            case requested
            case acknowledged
            case tooLate
        }

        let id: String
        let meetingID: String
        let meetingTitle: String
        var phase: Phase
        var cancellation: Cancellation = .none

        var isFinished: Bool {
            if cancellation == .acknowledged { return true }
            switch phase {
            case .resultsSynced, .failed: return true
            default: return false
            }
        }

        var statusKey: String {
            if cancellation == .acknowledged { return "Cancellation confirmed by Mac" }
            switch phase {
            case .queuedLocally: return "Saved on iPhone · Waiting to send"
            case .sending: return "Sending to Mac"
            case .awaitingReconnect: return "Not delivered · Waiting to reconnect"
            case .receivedDurably: return "Mac received and saved the task"
            case .processing: return "Processing on Mac"
            case .resultsSynced: return "Results synced"
            case .failed: return "Mac task failed"
            }
        }
    }

    enum Action: Equatable {
        case discover
        case selectDevice(String)
        case confirmPairing
        case retryConnection
        case unpair
        case retryTask(String)
        case requestCancellation(String)
    }

    typealias ActionHandler = @MainActor (Action) async throws -> Void

    var connection: Connection = .unavailable
    var devices: [Device] = []
    var jobs: [Job] = []
    private(set) var pendingAction: Action?
    private(set) var actionError: String?
    @ObservationIgnored private let onAction: ActionHandler?

    init(onAction: ActionHandler? = nil) {
        self.onAction = onAction
    }

    var hasTransportActions: Bool { onAction != nil }
    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }
    var isConnecting: Bool {
        switch connection {
        case .connecting, .discovering: return true
        default: return false
        }
    }
    var device: Device? {
        switch connection {
        case .offline(let device), .connected(let device, _): return device
        case .connecting(let device): return device
        case .pairing(let pairing): return pairing.device
        default: return nil
        }
    }
    var statusKey: String {
        switch connection {
        case .unavailable, .unpaired: return "Connect to Mac"
        case .discovering: return "Looking for a Mac"
        case .pairing: return "Confirm pairing"
        case .offline: return "Offline"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed: return "Connection needs attention"
        }
    }
    var explanation: String {
        switch connection {
        case .unavailable:
            return Self.text("Mac connection is unavailable because this app has no transport service configured.")
        case .unpaired:
            return Self.text("Open Transcript on your Mac, then look for it on your local network.")
        case .discovering:
            return Self.text("Keep Transcript open on your Mac. Discovered devices appear here.")
        case .pairing:
            return Self.text("Check that both devices show the same code, then confirm on each device.")
        case .offline:
            return Self.text("Your paired Mac is offline. Reconnect before submitting a new task.")
        case .connecting:
            return Self.text("Verifying the Mac's identity and connection.")
        case .connected(_, let modelReady):
            switch modelReady {
            case true: return Self.text("Mac connected · Processing model ready")
            case false: return Self.text("Mac connected · Processing model not ready")
            case nil: return Self.text("Mac connected · Processing model readiness unknown")
            }
        case .failed(let reason): return reason
        }
    }

    func submissionBlockReason(meetingID: String) -> String? {
        guard isConnected else { return explanation }
        guard !jobs.contains(where: { $0.meetingID == meetingID && !$0.isFinished }) else {
            return Self.text("This meeting already has an active Mac task.")
        }
        return nil
    }

    /// Does not invent connection changes, task receipts, or cancellation acks.
    /// The adapter must publish authoritative state; returning alone is not an ack.
    func perform(_ action: Action) async {
        guard pendingAction == nil, let onAction else { return }
        pendingAction = action
        actionError = nil
        defer { pendingAction = nil }
        do {
            try await onAction(action)
        } catch {
            actionError = error.localizedDescription
        }
    }

    static func text(_ key: String) -> String {
        LocalizationManager.shared.text(key)
    }

    #if DEBUG
    /// Explicit fixture input only; no launch argument can affect a release build.
    static func fixture(connection: Connection, jobs: [Job] = [], devices: [Device] = []) -> MacConnectionModel {
        let model = MacConnectionModel()
        model.connection = connection
        model.jobs = jobs
        model.devices = devices
        return model
    }
    #endif
}
