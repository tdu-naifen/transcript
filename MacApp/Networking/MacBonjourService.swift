import AppKit
import Combine
import Foundation
import Network
import Observation
import OSLog

/// Bonjour discovery is untrusted; MacPairingServer authenticates each connection.
@MainActor
@Observable
final class MacBonjourService {
    static let serviceType = "_vtscribe._tcp"

    enum State: Equatable, Sendable {
        case idle
        case starting
        case advertising
        case waiting(Failure)
        case failed(Failure)
    }

    struct Failure: Equatable, Sendable {
        let message: String
        let localNetworkDenied: Bool

        static func network(_ error: NWError) -> Self {
            if case .dns(-65570) = error {
                return .init(
                    message: String(
                        localized: "bonjour.failure.localNetworkDenied",
                        defaultValue: "Local network access was denied. Open System Settings → Privacy & Security → Local Network, enable this app, then retry."
                    ),
                    localNetworkDenied: true
                )
            }
            return .init(
                message: String.localizedStringWithFormat(
                    String(
                        localized: "bonjour.failure.unavailable",
                        defaultValue: "Bonjour is unavailable: %@ Check your network connection, then retry."
                    ),
                    error.localizedDescription
                ),
                localNetworkDenied: false
            )
        }
    }

    let serviceName: String
    let pairing: MacPairingServer
    private(set) var state: State = .idle
    private(set) var advertisedName: String?
    private(set) var isEnabled = false
    private(set) var advertisesMeetingCopy = false
    private(set) var isSuspended = false

    let connectionExplanation = String(
        localized: "bonjour.connectionExplanation",
        defaultValue: "Compare the six-digit code on both devices and approve on both. Pairing uses encrypted identity verification. Enable meeting receiving on this Mac before sending a copy from your iPhone."
    )

    var localNetworkDenied: Bool {
        switch state {
        case .waiting(let failure), .failed(let failure): failure.localNetworkDenied
        default: false
        }
    }

    @ObservationIgnored private let makeListener: @MainActor (String, Bool) throws -> any MacBonjourListening
    @ObservationIgnored private var listener: (any MacBonjourListening)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var listenerReady = false
    @ObservationIgnored private var registeredName: String?
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private let recoveryDelay: Duration
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryAttempt = 0
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var lifecycleObservers: [AnyCancellable] = []
    private static let enabledKey = "mac.connection.discoveryEnabled"
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.transcript.mac", category: "BonjourPublishing"
    )

    init(
        serviceName: String = Host.current().localizedName ?? "Transcript Mac",
        pairingStore: (any MacPairingIdentityStoring)? = nil,
        preferences: UserDefaults? = .standard
    ) {
        self.preferences = preferences
        recoveryDelay = .seconds(2)
        self.serviceName = Self.normalizedName(serviceName)
        let pairing = MacPairingServer(
            name: Self.normalizedName(serviceName), store: pairingStore ?? MacPairingKeychainStore()
        )
        self.pairing = pairing
        self.makeListener = { try NetworkMacBonjourListener(name: $0, pairing: pairing, meetingCopy: $1) }
    }

    init(
        serviceName: String,
        preferences: UserDefaults? = nil,
        recoveryDelay: Duration = .seconds(2),
        pairing: MacPairingServer? = nil,
        makeListener: @escaping @MainActor (String) throws -> any MacBonjourListening
    ) {
        self.preferences = preferences
        self.recoveryDelay = recoveryDelay
        self.serviceName = Self.normalizedName(serviceName)
        self.pairing = pairing ?? MacPairingServer(name: Self.normalizedName(serviceName))
        self.makeListener = { name, _ in try makeListener(name) }
    }

    isolated deinit {
        recoveryTask?.cancel()
        listener?.cancel()
        pairing.stop()
    }

    func restoreDiscovery() {
        guard !restored else { return }
        restored = true
        lifecycleObservers = [
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        ].map { publisher in
            publisher.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.isSuspended == true { self?.resumeAfterWake() }
                    else { self?.recoverIfNeeded() }
                }
            }
        }
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.suspendForSleep() }
                }
        )
        let shouldRestore = preferences?.object(forKey: Self.enabledKey) as? Bool
            ?? !pairing.peers.isEmpty
        logger.info("Restoring discovery: enabled=\(shouldRestore), trusted device count=\(self.pairing.peers.count)")
        if case .failed(let message) = pairing.state {
            logger.error("Could not restore pairing state: \(message, privacy: .public)")
        }
        guard shouldRestore else { return }
        isEnabled = true
        startListener()
    }

    /// Explicit enablement permits new pairing; automatic recovery only accepts trusted peers.
    func start() {
        isEnabled = true
        preferences?.set(true, forKey: Self.enabledKey)
        startListener(allowNewPairing: true)
    }

    func advertiseMeetingCopy(_ enabled: Bool) {
        guard advertisesMeetingCopy != enabled else { return }
        advertisesMeetingCopy = enabled
        guard isEnabled, listener != nil else { return }
        invalidateListener(stopPairing: false)
        startListener()
    }

    private func startListener(allowNewPairing: Bool = false) {
        guard !isSuspended else { return }
        guard listener == nil else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        generation = UUID()
        let currentGeneration = generation
        listenerReady = false
        registeredName = nil
        advertisedName = nil
        state = .starting
        if allowNewPairing { pairing.enablePairing() }
        logger.info("Starting Bonjour advertisement with authenticated pairing.")

        do {
            let listener = try makeListener(serviceName, advertisesMeetingCopy)
            self.listener = listener
            listener.start { [weak self] event in
                guard let self, self.generation == currentGeneration else { return }
                self.handle(event)
            }
        } catch {
            let failure: Failure
            if let error = error as? NWError {
                failure = .network(error)
            } else {
                failure = .init(
                    message: String.localizedStringWithFormat(
                        String(
                            localized: "bonjour.failure.start",
                            defaultValue: "Could not start Bonjour: %@ Retry to start discovery."
                        ),
                        error.localizedDescription
                    ),
                    localNetworkDenied: false
                )
            }
            fail(failure)
        }
    }

    func stop() {
        isEnabled = false
        preferences?.set(false, forKey: Self.enabledKey)
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempt = 0
        invalidateListener()
        state = .idle
        logger.info("Bonjour advertisement stopped.")
    }

    func suspendForSleep() {
        isSuspended = true
        recoveryTask?.cancel()
        recoveryTask = nil
        invalidateListener()
        if !localNetworkDenied { state = .idle }
    }

    func resumeAfterWake() {
        guard isSuspended else { return }
        isSuspended = false
        guard isEnabled, !localNetworkDenied else { return }
        startListener()
    }

    /// An explicit retry replaces the listener and invalidates all previous callbacks.
    func retry() {
        stop()
        start()
    }

    func recoverIfNeeded() {
        guard isEnabled, !isSuspended, !localNetworkDenied else { return }
        switch state {
        case .failed, .waiting:
            recoveryTask?.cancel()
            recoveryTask = nil
            invalidateListener(stopPairing: false)
            startListener()
        case .idle:
            startListener()
        case .starting, .advertising:
            break
        }
    }

    private func handle(_ event: MacBonjourListenerEvent) {
        switch event {
        case .ready:
            listenerReady = true
            updateAdvertisingState()
        case .registered(let name):
            registeredName = name
            updateAdvertisingState()
        case .unregistered(let name):
            guard registeredName == name else { return }
            registeredName = nil
            advertisedName = nil
            if listenerReady { state = .starting }
        case .waiting(let failure):
            listenerReady = false
            advertisedName = nil
            if failure.localNetworkDenied {
                fail(failure)
            } else {
                state = .waiting(failure)
                logger.warning("Bonjour is waiting: \(failure.message, privacy: .public)")
            }
        case .failed(let failure):
            fail(failure)
        case .cancelled:
            fail(.init(
                message: String(
                    localized: "bonjour.failure.cancelled",
                    defaultValue: "Bonjour stopped unexpectedly. Retry to make this Mac discoverable."
                ),
                localNetworkDenied: false
            ))
        }
    }

    private func updateAdvertisingState() {
        guard listenerReady else { return }
        guard let registeredName else {
            state = .starting
            return
        }
        advertisedName = registeredName
        state = .advertising
        recoveryAttempt = 0
        logger.info("Bonjour service registered. Discovery does not indicate an authenticated connection.")
    }

    private func fail(_ failure: Failure) {
        invalidateListener(stopPairing: false)
        state = .failed(failure)
        logger.error("Bonjour publishing failed: \(failure.message, privacy: .public)")
        guard isEnabled, !failure.localNetworkDenied else { return }
        let delay = recoveryDelay * (1 << min(recoveryAttempt, 4))
        recoveryAttempt += recoveryAttempt < 4 ? 1 : 0
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.recoverIfNeeded()
        }
    }

    private func invalidateListener(stopPairing: Bool = true) {
        generation = UUID()
        let oldListener = listener
        listener = nil
        listenerReady = false
        registeredName = nil
        advertisedName = nil
        oldListener?.cancel()
        if stopPairing { pairing.stop() }
        else { pairing.disableNewPairing() }
    }

    private static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = trimmed.isEmpty ? "Transcript Mac" : trimmed
        // A Bonjour instance label is limited to 63 UTF-8 bytes, not 63 characters.
        while result.utf8.count > 63 { result.removeLast() }
        return result.isEmpty ? "Transcript Mac" : result
    }
}

enum MacBonjourListenerEvent: Sendable {
    case ready
    case registered(String)
    case unregistered(String)
    case waiting(MacBonjourService.Failure)
    case failed(MacBonjourService.Failure)
    case cancelled
}

@MainActor
protocol MacBonjourListening: AnyObject {
    func start(onEvent: @escaping @MainActor @Sendable (MacBonjourListenerEvent) -> Void)
    func cancel()
}

@MainActor
private final class NetworkMacBonjourListener: MacBonjourListening {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.transcript.mac-bonjour-publisher")
    private var active = false

    init(name: String, pairing: MacPairingServer, meetingCopy: Bool) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: name, type: MacBonjourService.serviceType,
            txtRecord: meetingCopy ? NetService.data(fromTXTRecord: ["meeting-copy": Data("2".utf8)]) : nil
        )
        listener.newConnectionHandler = { [weak self, weak pairing] connection in
            Task { @MainActor in
                guard self?.active == true, let pairing else { connection.cancel(); return }
                pairing.accept(connection)
            }
        }
    }

    func start(onEvent: @escaping @MainActor @Sendable (MacBonjourListenerEvent) -> Void) {
        active = true
        listener.stateUpdateHandler = { state in
            let event: MacBonjourListenerEvent
            switch state {
            case .ready: event = .ready
            case .waiting(let error): event = .waiting(.network(error))
            case .failed(let error): event = .failed(.network(error))
            case .cancelled: event = .cancelled
            case .setup: return
            @unknown default: return
            }
            Task { @MainActor in onEvent(event) }
        }
        listener.serviceRegistrationUpdateHandler = { change in
            let event: MacBonjourListenerEvent
            switch change {
            case .add(let endpoint):
                guard case .service(let name, _, _, _) = endpoint else { return }
                event = .registered(name)
            case .remove(let endpoint):
                guard case .service(let name, _, _, _) = endpoint else { return }
                event = .unregistered(name)
            @unknown default: return
            }
            Task { @MainActor in onEvent(event) }
        }
        listener.start(queue: queue)
    }

    func cancel() {
        active = false
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.cancel()
    }
}
