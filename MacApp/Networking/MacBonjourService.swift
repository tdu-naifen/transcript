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

    let connectionExplanation = String(
        localized: "bonjour.connectionExplanation",
        defaultValue: "Compare the six-digit code on both devices and approve on both. Pairing uses encrypted identity verification. Meeting transfer is not available."
    )

    var localNetworkDenied: Bool {
        switch state {
        case .waiting(let failure), .failed(let failure): failure.localNetworkDenied
        default: false
        }
    }

    @ObservationIgnored private let makeListener: @MainActor (String) throws -> any MacBonjourListening
    @ObservationIgnored private var listener: (any MacBonjourListening)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var listenerReady = false
    @ObservationIgnored private var registeredName: String?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.transcript.mac", category: "BonjourPublishing"
    )

    init(
        serviceName: String = Host.current().localizedName ?? "Transcript Mac",
        pairingStore: (any MacPairingIdentityStoring)? = nil
    ) {
        self.serviceName = Self.normalizedName(serviceName)
        let pairing = MacPairingServer(
            name: Self.normalizedName(serviceName), store: pairingStore ?? MacPairingKeychainStore()
        )
        self.pairing = pairing
        self.makeListener = { try NetworkMacBonjourListener(name: $0, pairing: pairing) }
    }

    init(
        serviceName: String,
        makeListener: @escaping @MainActor (String) throws -> any MacBonjourListening
    ) {
        self.serviceName = Self.normalizedName(serviceName)
        self.pairing = MacPairingServer(name: Self.normalizedName(serviceName))
        self.makeListener = makeListener
    }

    isolated deinit {
        listener?.cancel()
        pairing.stop()
    }

    /// Call only in response to explicit user enablement. Repeated starts are idempotent.
    func start() {
        guard listener == nil else { return }
        generation = UUID()
        let currentGeneration = generation
        listenerReady = false
        registeredName = nil
        advertisedName = nil
        state = .starting
        pairing.enablePairing()
        logger.info("Starting Bonjour advertisement with authenticated pairing.")

        do {
            let listener = try makeListener(serviceName)
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
        invalidateListener()
        state = .idle
        logger.info("Bonjour advertisement stopped.")
    }

    /// An explicit retry replaces the listener and invalidates all previous callbacks.
    func retry() {
        stop()
        start()
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
        logger.info("Bonjour service registered. Discovery does not indicate an authenticated connection.")
    }

    private func fail(_ failure: Failure) {
        invalidateListener()
        state = .failed(failure)
        logger.error("Bonjour publishing failed: \(failure.message, privacy: .public)")
    }

    private func invalidateListener() {
        generation = UUID()
        let oldListener = listener
        listener = nil
        listenerReady = false
        registeredName = nil
        advertisedName = nil
        oldListener?.cancel()
        pairing.stop()
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

    init(name: String, pairing: MacPairingServer) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: name, type: MacBonjourService.serviceType)
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
