import Foundation
import Network
import Observation
import OSLog
import TranscriptCore

/// App presentation only. A long-lived service must publish verified snapshots and
/// own discovery, pairing, durable outbox work, receipts, and cancellation requests.
@MainActor
@Observable
final class MacConnectionModel {
    struct Device: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        var meetingCopyProbeHint = false
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
            case copied
            case stoppedLocally
            case copyFailed(MeetingCopyProblem)
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
        var failurePersistenceFailed = false

        var canRetry: Bool {
            if case .copyFailed(let problem) = phase { return problem.canRetry }
            return phase == .awaitingReconnect || phase == .stoppedLocally
        }

        var isFinished: Bool {
            if cancellation == .acknowledged { return true }
            switch phase {
            case .resultsSynced, .failed, .copied, .stoppedLocally: return true
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
            case .copied: return "Immutable copy saved on Mac"
            case .stoppedLocally: return "Stopped on iPhone · Mac may retain a copy"
            case .copyFailed(let problem): return problem.statusKey
            case .failed: return "Mac task failed"
            }
        }
    }

    enum Action: Equatable {
        case discover
        case selectDevice(String)
        case confirmPairing
        case cancelPairing
        case retryConnection
        case unpair
        case retryTask(String)
        case requestCancellation(String)
    }

    typealias ActionHandler = @MainActor (Action) async throws -> Void

    struct RecoveryTiming {
        var discoveryWindow: TimeInterval = 15
        var backoff: [TimeInterval] = [0, 1, 3]
    }

    var connection: Connection = .unavailable
    var devices: [Device] = []
    var jobs: [Job] = []
    private(set) var pendingAction: Action?
    private(set) var actionError: String?
    private(set) var localNetworkDenied = false
    private(set) var discoveryTimedOut = false
    private(set) var trustedDevice: Device?
    private(set) var supportsMeetingTransfer = false
    @ObservationIgnored private var onAction: ActionHandler?
    @ObservationIgnored private let discovery: (any MacDiscovering)?
    @ObservationIgnored private var discoveryTimeout: Task<Void, Never>?
    @ObservationIgnored private var pairingClient: IOSMacPairingClient?
    @ObservationIgnored private var sender: MeetingCopySender?
    @ObservationIgnored private var selectedCandidate: Device?
    @ObservationIgnored private var actionGeneration = UUID()
    @ObservationIgnored private var operationTasks: [UUID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var persistentIntents: [(id: UUID, action: Action, task: Task<Void, Never>)] = []
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryGeneration = UUID()
    @ObservationIgnored private var discoveryGeneration = UUID()
    @ObservationIgnored private var networkGeneration = UUID()
    @ObservationIgnored private var monitoringNetwork = false
    @ObservationIgnored private var browsing = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var didResume = false
    @ObservationIgnored private var recoveryAllowed = true
    @ObservationIgnored private let recoveryTiming: RecoveryTiming

    init(discovery: (any MacDiscovering)? = nil, recoveryTiming: RecoveryTiming = .init(), onAction: ActionHandler? = nil) {
        self.onAction = onAction
        self.discovery = discovery
        self.recoveryTiming = recoveryTiming
        if discovery != nil { connection = .unpaired }
    }

    func enablePairing(using suppliedClient: IOSMacPairingClient? = nil) {
        guard pairingClient == nil, onAction == nil, discovery != nil else { return }
        do {
            let client = try suppliedClient ?? Self.makePairingClient()
            pairingClient = client
            client.onUpdate = { [weak self] state in self?.applyPairing(state) }
            client.onTransferReadiness = { [weak self] ready in self?.supportsMeetingTransfer = ready }
            onAction = { [weak self] action in
                guard let self else { throw CancellationError() }
                switch action {
                case .retryTask(let id):
                    guard let sender = self.sender else { throw PairingActionError.transferUnavailable }
                    do { try await sender.retry(id: id) }
                    catch { throw MeetingCopyProblem(error) }
                case .requestCancellation(let id):
                    guard let sender = self.sender else { throw PairingActionError.transferUnavailable }
                    do { try await sender.cancel(id: id) }
                    catch { throw MeetingCopyProblem(error) }
                default:
                    try self.handlePairingAction(action)
                }
            }

            try client.restoreTrust()
            trustedDevice = client.pairedPeer.map(Self.device)
            connection = trustedDevice.map(Connection.offline) ?? .unpaired
            if didResume {
                monitorNetwork()
                beginRecovery(source: "trust-restored")
            }
        } catch {
            connection = .failed(reason: Self.text(error.localizedDescription))
        }
    }

    func enableMeetingCopies(database: AppDatabase, store: AudioFileStore, using suppliedSender: MeetingCopySender? = nil) async {
        guard sender == nil, let pairingClient else { return }
        let sender = suppliedSender ?? MeetingCopySender(client: pairingClient, database: database, store: store)
        self.sender = sender
        sender.onChange = { [weak self] in Task { await self?.refreshCopyJobs() } }
        await refreshCopyJobs()
    }

    func sendMeetingCopy(meetingID: String) async throws {
        guard foreground, persistentIntents.isEmpty, isConnected, let sender else { throw PairingActionError.transferUnavailable }
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            try await sender.enqueue(meetingID: meetingID)
        }
        operationTasks[id] = task
        defer { operationTasks[id] = nil }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        catch { throw MeetingCopyProblem(error) }
        await refreshCopyJobs()
    }

    func refreshCopyJobs() async {
        guard let sender else { return }
        do {
            let entries = try await sender.summaries()
            jobs = entries.map { entry in
                let manifest = try? MeetingCopyWire.decodeManifest(entry.manifest)
                let phase: Job.Phase
                switch entry.state {
                case "done": phase = .copied
                case "cancelled": phase = .stoppedLocally
                case "stale": phase = .failed(reason: Self.text("The meeting changed after export. This frozen copy cannot be sent."))
                default:
                    if sender.sendingID == entry.id {
                        phase = .sending
                    } else if let problem = sender.unpersistedFailures[entry.id] {
                        phase = .copyFailed(problem)
                    } else if let error = entry.error {
                        phase = .copyFailed(.init(stored: error))
                    } else {
                        phase = .awaitingReconnect
                    }
                }
                return Job(id: entry.id, meetingID: entry.meetingId,
                           meetingTitle: manifest?.title ?? entry.meetingId, phase: phase,
                           failurePersistenceFailed: sender.unpersistedFailures[entry.id] != nil)
            }
        } catch {
            actionError = Self.text("Could not read the saved meeting-copy queue.")
            if !sender.unpersistedFailures.isEmpty {
                actionError = Self.text(MeetingCopyProblem.persistenceMessageKey)
            }
        }
    }

    private static func makePairingClient() throws -> IOSMacPairingClient {
        var namespace = "com.transcript.ios.pairing.v1"
        #if DEBUG
        if let runID = try TestStorageConfiguration.resolve().runID {
            namespace += ".test.\(runID.uuidString)"
        }
        #endif
        return IOSMacPairingClient(
            store: MacPairingKeychainStore(service: namespace), name: "iPhone"
        )
    }

    private func handlePairingAction(_ action: Action) throws {
        guard let client = pairingClient else { throw PairingActionError.unavailable }
        switch action {
        case .selectDevice(let id):
            cancelRecovery()
            recoveryAllowed = true
            guard let endpoint = discovery?.endpoint(for: id),
                  let candidate = devices.first(where: { $0.id == id }) else {
                throw PairingActionError.candidateUnavailable
            }
            selectedCandidate = candidate
            client.connect(to: endpoint, allowMeetingCopyProbe: candidate.meetingCopyProbeHint, requiredPeer: client.pairedPeer)
        case .confirmPairing:
            client.approve()
        case .cancelPairing:
            recoveryAllowed = false
            cancelRecovery()
            stopBrowsing()
            client.disconnect()
        case .retryConnection:
            cancelRecovery()
            recoveryAllowed = true
            localNetworkDenied = false
            stopBrowsing()
            client.disconnect()
            if trustedDevice != nil { beginRecovery(source: "explicit-retry") }
            else { startDiscovery() }
        case .unpair:
            recoveryAllowed = false
            cancelRecovery()
            stopBrowsing()
            try client.unpair()
            trustedDevice = client.pairedPeer.map(Self.device)
            selectedCandidate = nil
        case .discover:
            startDiscovery()
        case .retryTask, .requestCancellation:
            throw PairingActionError.transferUnavailable
        }
    }

    private func applyPairing(_ state: IOSMacPairingClient.State) {
        trustedDevice = pairingClient?.pairedPeer.map(Self.device)
        switch state {
        case .idle:
            connection = trustedDevice.map(Connection.offline) ?? .unpaired
        case .connecting:
            connection = .connecting(trustedDevice ?? selectedCandidate)
        case .awaitingApproval(let peer, let code, let approvedLocally):
            connection = .pairing(Pairing(
                device: Self.device(peer), code: code,
                confirmedOnPhone: approvedLocally, confirmedOnMac: false
            ))
        case .connected(let peer):
            connection = .connected(Self.device(peer), modelReady: nil)
        case .disconnected(let peer):
            connection = peer.map { .offline(Self.device($0)) } ?? .unpaired
        case .failed(let message):
            connection = .failed(reason: Self.text(message))
            beginRecovery(source: "session-failed")
        }
    }

    private static func device(_ peer: MacPairedDevice) -> Device {
        Device(id: peer.id, name: peer.name)
    }

    func endConnectionPresentation() {
        // An authenticated transport belongs to the app, not the connection sheet.
        guard !isConnected else { return }
        recoveryAllowed = false
        cancelRecovery()
        cancelAction()
        stopBrowsing()
        switch connection {
        case .pairing, .connecting:
            pairingClient?.disconnect()
        default:
            break
        }
    }

    func suspendConnection() {
        foreground = false
        didResume = false
        networkGeneration = UUID()
        monitoringNetwork = false
        discovery?.stopMonitoringNetwork()
        cancelRecovery()
        cancelAction()
        stopBrowsing()
        selectedCandidate = nil
        devices = []
        supportsMeetingTransfer = false
        pairingClient?.disconnect()
        connection = trustedDevice.map(Connection.offline) ?? (pairingClient == nil ? .unavailable : .unpaired)
    }

    func resumeConnection() {
        guard !didResume else { return }
        didResume = true
        foreground = true
        recoveryAllowed = true
        localNetworkDenied = false
        monitorNetwork()
        beginRecovery(source: "foreground-or-unlock")
    }

    private func monitorNetwork() {
        guard !monitoringNetwork, discovery != nil else { return }
        monitoringNetwork = true
        let generation = networkGeneration
        discovery?.startMonitoringNetwork { [weak self] in
            guard let self, self.networkGeneration == generation else { return }
            self.beginRecovery(source: "network-change")
        }
    }

    private func cancelAction() {
        actionGeneration = UUID()
        operationTasks.values.forEach { $0.cancel() }
        pendingAction = persistentIntents.first?.action
    }

    private func cancelRecovery() {
        recoveryGeneration = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func beginRecovery(source: String = "discovery-change") {
        guard foreground, recoveryAllowed, !localNetworkDenied, trustedDevice != nil,
              let client = pairingClient, let pin = client.pairedPeer,
              discovery != nil, recoveryTask == nil, !isConnected else { return }
        let generation = UUID()
        recoveryGeneration = generation
        MacNetworkDiagnostics.logger.info("event=recovery-start source=\(source, privacy: .public) generation=\(generation.uuidString, privacy: .public)")
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            var lastFailure: String?
            defer {
                if self.recoveryGeneration == generation { self.recoveryTask = nil }
            }
            do {
                // Existing sends own asynchronous export/receipt cleanup. Let them
                // retire before exposing a new session to any old continuation.
                let drainDeadline = ContinuousClock.now.advanced(by: .seconds(self.recoveryTiming.discoveryWindow))
                while !self.operationTasks.isEmpty || !self.persistentIntents.isEmpty || self.sender?.sendingID != nil {
                    try await Task.sleep(for: .milliseconds(50))
                    try Task.checkCancellation()
                    guard ContinuousClock.now < drainDeadline else { return }
                }
                for delay in self.recoveryTiming.backoff {
                    try await Task.sleep(for: .seconds(delay))
                    try Task.checkCancellation()
                    guard self.recoveryGeneration == generation, self.foreground else { return }
                    self.startDiscovery(clearActionError: false)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(self.recoveryTiming.discoveryWindow))
                    var attempted = Set<String>()
                    while ContinuousClock.now < deadline {
                        try Task.checkCancellation()
                        guard self.recoveryGeneration == generation, self.foreground else { return }
                        if self.isConnected { return }
                        if self.localNetworkDenied { return }
                        if case .failed(let reason) = self.connection { lastFailure = reason }
                        if case .connecting = client.state {
                            try await Task.sleep(for: .milliseconds(50))
                            continue
                        }
                        // Labels only prioritize candidates. Every connection uses the
                        // retained cryptographic pin; none can enter first-time pairing.
                        let candidates = self.devices.sorted {
                            let left = $0.name == self.trustedDevice?.name
                            let right = $1.name == self.trustedDevice?.name
                            return left == right ? $0.id < $1.id : left
                        }
                        if attempted.count < 4,
                           let candidate = candidates.first(where: { !attempted.contains($0.id) }),
                           let endpoint = self.discovery?.endpoint(for: candidate.id) {
                            attempted.insert(candidate.id)
                            self.selectedCandidate = candidate
                            MacNetworkDiagnostics.endpoint(endpoint, event: "recovery-candidate", generation: generation)
                            client.connect(to: endpoint, allowMeetingCopyProbe: candidate.meetingCopyProbeHint, requiredPeer: pin)
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    self.stopBrowsing()
                    client.disconnect()
                }
                self.discoveryTimedOut = true
                if let lastFailure { self.connection = .failed(reason: lastFailure) }
                else { self.connection = self.trustedDevice.map(Connection.offline) ?? .unpaired }
            } catch {
                // The cancelling lifecycle/action owns subsequent presentation.
            }
        }
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
            if supportsMeetingTransfer {
                return Self.text("Ready to receive an immutable meeting copy. Processing and result sync are not included.")
            }
            if pairingClient?.canProbeMeetingTransfer == true {
                return Self.text("Securely paired. Send checks compatibility before sharing meeting data.")
            }
            guard supportsMeetingTransfer else {
                return Self.text("Securely paired. Receiving availability has not been confirmed. Check receiving on the Mac, then discover and reconnect.")
            }
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
        guard supportsMeetingTransfer || pairingClient?.canProbeMeetingTransfer == true else {
            return Self.text("Receiving is not advertised. It may be turned off on the Mac, the Mac version may be older, or discovery may be stale. Check receiving, then discover and reconnect; update the Mac if needed.")
        }
        guard !jobs.contains(where: { $0.meetingID == meetingID && !$0.isFinished }) else {
            return Self.text("This meeting already has an active Mac task.")
        }
        return nil
    }

    /// Does not invent connection changes, task receipts, or cancellation acks.
    /// The adapter must publish authoritative state; returning alone is not an ack.
    func perform(_ action: Action) async {
        switch action {
        case .unpair, .requestCancellation:
            await performPersistentIntent(action)
            return
        default: break
        }
        if action == .cancelPairing {
            cancelAction()
            recoveryAllowed = false
            cancelRecovery()
            stopBrowsing()
            pairingClient?.disconnect()
        }
        guard foreground else { return }
        guard pendingAction == nil else { return }
        if case .selectDevice = action, !operationTasks.isEmpty || sender?.sendingID != nil {
            actionError = Self.text("Another meeting copy is being prepared or sent. Wait for it to finish.")
            return
        }
        if discovery != nil, action == .discover || (action == .retryConnection && !isConnected && pairingClient == nil) {
            cancelRecovery()
            recoveryAllowed = true
            startDiscovery()
            return
        }
        guard let onAction else {
            actionError = Self.text("This Mac was discovered, but secure pairing is not available yet. No meeting data has been sent.")
            return
        }
        pendingAction = action
        let generation = UUID()
        actionGeneration = generation
        actionError = nil
        let task = Task {
            try Task.checkCancellation()
            try await onAction(action)
        }
        operationTasks[generation] = task
        defer {
            operationTasks[generation] = nil
            if actionGeneration == generation {
                pendingAction = nil
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if actionGeneration == generation { actionError = Self.text(error.localizedDescription) }
        }
    }

    private func performPersistentIntent(_ action: Action) async {
        if let existing = persistentIntents.first(where: { $0.action == action }) {
            await existing.task.value
            return
        }
        guard let onAction else {
            actionError = Self.text("Secure pairing is unavailable. Reopen the app and try again.")
            return
        }
        // Stop/Unpair are accepted local persistence intents, not cancellable
        // network work. Finish them even if their UI task or scene disappears.
        cancelAction()
        recoveryAllowed = false
        cancelRecovery()
        stopBrowsing()
        let previous = persistentIntents.last?.task
        if previous == nil { actionError = nil }
        let id = UUID()
        let task = Task { [self] in
            await previous?.value
            do { try await onAction(action) }
            catch { actionError = Self.text(error.localizedDescription) }
            persistentIntents.removeAll { $0.id == id }
            pendingAction = persistentIntents.first?.action
        }
        persistentIntents.append((id, action, task))
        pendingAction = persistentIntents.first?.action
        await task.value
    }

    func stopDiscovery() {
        recoveryAllowed = false
        cancelRecovery()
        stopBrowsing()
        if !isConnected { pairingClient?.disconnect() }
    }

    private func stopBrowsing() {
        browsing = false
        discoveryGeneration = UUID()
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        discovery?.stop()
        if case .discovering = connection { connection = trustedDevice.map(Connection.offline) ?? .unpaired }
    }

    private func startDiscovery(clearActionError: Bool = true) {
        stopBrowsing()
        pairingClient?.disconnect()
        devices = []
        if clearActionError { actionError = nil }
        localNetworkDenied = false
        discoveryTimedOut = false
        connection = .discovering
        selectedCandidate = nil
        browsing = true
        let generation = discoveryGeneration
        discovery?.onUpdate = { [weak self] update in
            guard let self, self.discoveryGeneration == generation, self.browsing else { return }
            self.applyDiscovery(update)
        }
        discovery?.start()
        discoveryTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.discoveryGeneration == generation, case .discovering = connection else { return }
            discoveryTimedOut = devices.isEmpty
        }
    }

    private func applyDiscovery(_ update: MacDiscoveryUpdate) {
        guard browsing, foreground else { return }
        switch update {
        case .devices(let devices):
            self.devices = devices
            if !devices.isEmpty { discoveryTimedOut = false }
            if let selectedCandidate {
                if let current = devices.first(where: { $0.id == selectedCandidate.id }) {
                    self.selectedCandidate = current
                    pairingClient?.updateMeetingCopyProbeHint(current.meetingCopyProbeHint)
                    if let client = pairingClient, case .disconnected = client.state { beginRecovery() }
                } else {
                    // A disappearing advertisement is not a failed authenticated
                    // socket. Keep its selection so a returning TXT record refreshes it.
                    if !isConnected {
                        self.selectedCandidate = nil
                        pairingClient?.disconnect()
                        beginRecovery()
                    }
                }
            }
        case .permissionDenied:
            recoveryAllowed = false
            cancelRecovery()
            stopBrowsing()
            pairingClient?.disconnect()
            localNetworkDenied = true
            connection = .failed(reason: Self.text("Local network access is off. Enable Local Network for Transcript in Settings, then try again."))
        case .failed(let message):
            stopBrowsing()
            guard !isConnected else { return }
            pairingClient?.disconnect()
            connection = .failed(reason: message)
            beginRecovery()
        }
    }

    static func text(_ key: String) -> String {
        let recoveryText = LocalizationManager.shared.text(key, table: "MacConnectionRecovery")
        if recoveryText != key { return recoveryText }
        let copyText = LocalizationManager.shared.text(key, table: "MeetingCopy")
        if copyText != key { return copyText }
        let pairingText = LocalizationManager.shared.text(key, table: "MacPairing")
        if pairingText != key { return pairingText }
        let discoveryText = LocalizationManager.shared.text(key, table: "AppleSpeech")
        return discoveryText == key ? LocalizationManager.shared.text(key) : discoveryText
    }

    private enum PairingActionError: LocalizedError {
        case unavailable
        case candidateUnavailable
        case transferUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "Secure pairing is unavailable. Reopen the app and try again."
            case .candidateUnavailable: "This Mac is no longer in the discovery results. Find your Mac again."
            case .transferUnavailable: "This connection supports pairing only. Meeting transfer is not available yet."
            }
        }
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
