import Foundation
import Observation

/// App presentation only. A long-lived service must publish verified snapshots and
/// own discovery, pairing, durable outbox work, receipts, and cancellation requests.
@MainActor
@Observable
final class MacConnectionModel {
    struct Device: Identifiable, Equatable, Sendable {
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
    private(set) var localNetworkDenied = false
    private(set) var discoveryTimedOut = false
    @ObservationIgnored private let onAction: ActionHandler?
    @ObservationIgnored private let discovery: (any MacDiscovering)?
    @ObservationIgnored private var discoveryTimeout: Task<Void, Never>?

    init(discovery: (any MacDiscovering)? = nil, onAction: ActionHandler? = nil) {
        self.onAction = onAction
        self.discovery = discovery
        if discovery != nil { connection = .unpaired }
        discovery?.onUpdate = { [weak self] update in self?.applyDiscovery(update) }
    }

    var canDiscover: Bool { discovery != nil || onAction != nil }
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
        guard pendingAction == nil else { return }
        if discovery != nil, action == .discover || (action == .retryConnection && !isConnected) {
            startDiscovery()
            return
        }
        guard let onAction else {
            actionError = Self.text("This Mac was discovered, but secure pairing is not available yet. No meeting data has been sent.")
            return
        }
        pendingAction = action
        actionError = nil
        defer { pendingAction = nil }
        do {
            try await onAction(action)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func stopDiscovery() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        discovery?.stop()
        if case .discovering = connection { connection = .unpaired }
    }

    private func startDiscovery() {
        stopDiscovery()
        devices = []
        actionError = nil
        localNetworkDenied = false
        discoveryTimedOut = false
        connection = .discovering
        discovery?.start()
        discoveryTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, case .discovering = connection else { return }
            discoveryTimedOut = devices.isEmpty
        }
    }

    private func applyDiscovery(_ update: MacDiscoveryUpdate) {
        guard case .discovering = connection else { return }
        switch update {
        case .devices(let devices):
            self.devices = devices
            if !devices.isEmpty { discoveryTimedOut = false }
        case .permissionDenied:
            stopDiscovery()
            localNetworkDenied = true
            connection = .failed(reason: Self.text("Local network access is off. Enable Local Network for Transcript in Settings, then try again."))
        case .failed(let message):
            stopDiscovery()
            connection = .failed(reason: message)
        }
    }

    static func text(_ key: String) -> String {
        let discoveryText = LocalizationManager.shared.text(key, table: "AppleSpeech")
        return discoveryText == key ? LocalizationManager.shared.text(key) : discoveryText
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
