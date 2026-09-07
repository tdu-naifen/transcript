import Foundation
import Network
import OSLog

@MainActor
protocol MacDiscovering: AnyObject {
    var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)? { get set }
    func endpoint(for deviceID: String) -> NWEndpoint?
    func start()
    func stop()
    func startMonitoringNetwork(onChange: @escaping @MainActor () -> Void)
    func stopMonitoringNetwork()
}

extension MacDiscovering {
    func startMonitoringNetwork(onChange: @escaping @MainActor () -> Void) {}
    func stopMonitoringNetwork() {}
}

enum MacNetworkDiagnostics {
    static let logger = Logger(subsystem: "com.transcript.ios", category: "MacConnection")

    static func endpoint(_ endpoint: NWEndpoint, event: String, generation: UUID) {
        let scope: String
        if case .service(_, _, _, let interface) = endpoint {
            scope = interface.map { "\($0.name):\($0.type)" } ?? "unscoped"
        } else { scope = "non-service" }
        logger.info("event=\(event, privacy: .public) generation=\(generation.uuidString, privacy: .public) endpoint=\(String(describing: endpoint), privacy: .private(mask: .hash)) scope=\(scope, privacy: .public)")
    }

    static func path(_ path: NWPath?, event: String, generation: UUID) {
        let status = path.map { String(describing: $0.status) } ?? "unknown"
        let interfaces = path?.availableInterfaces.map {
            "\($0.name):\($0.type):typeUsed=\(path?.usesInterfaceType($0.type) == true)"
        }.sorted().joined(separator: ",") ?? "unknown"
        logger.info("event=\(event, privacy: .public) generation=\(generation.uuidString, privacy: .public) path=\(status, privacy: .public) interfaces=\(interfaces, privacy: .public)")
    }

    static func errorCode(_ error: NWError) -> String {
        switch error {
        case .posix(let code): "posix-\(code.rawValue)"
        case .dns(let code): "dns-\(code)"
        case .tls(let code): "tls-\(code)"
        default: "other"
        }
    }
}

enum MacDiscoveryUpdate: Sendable {
    case devices([MacConnectionModel.Device])
    case permissionDenied
    case failed(String)
}

/// Bonjour results are candidates, never authenticated device identities.
@MainActor
final class BonjourMacDiscovery: MacDiscovering {
    var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var generation = UUID()
    private let queue = DispatchQueue(label: "com.transcript.mac-discovery")
    private var monitor: NWPathMonitor?
    private var monitorGeneration = UUID()
    private var networkPath: NWPath?

    func startMonitoringNetwork(onChange: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        let generation = monitorGeneration
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.monitorGeneration == generation else { return }
                MacNetworkDiagnostics.path(path, event: "network-hint", generation: generation)
                if self.networkPathDidChange(path) { onChange() }
            }
        }
        monitor.start(queue: queue)
    }

    func stopMonitoringNetwork() {
        monitorGeneration = UUID()
        monitor?.cancel()
        monitor = nil
        networkPath = nil
    }

    func networkPathDidChange(_ path: NWPath) -> Bool {
        let previous = networkPath
        networkPath = path
        // Compare full route state, not just interface labels. Initial snapshots
        // and unchanged paths do not restart an exhausted search.
        return previous.map { $0 != path } == true && path.status == .satisfied
    }

    func start() {
        stop()
        let generation = self.generation
        MacNetworkDiagnostics.logger.info("event=discovery-start generation=\(generation.uuidString, privacy: .public)")
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_vtscribe._tcp", domain: nil),
            using: parameters
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .waiting(let error), .failed(let error):
                    MacNetworkDiagnostics.logger.info("event=discovery-unavailable generation=\(generation.uuidString, privacy: .public) code=\(MacNetworkDiagnostics.errorCode(error), privacy: .public)")
                    if case .dns(let code) = error, code == -65570 {
                        self.onUpdate?(.permissionDenied)
                    } else {
                        self.onUpdate?(.failed(error.localizedDescription))
                    }
                    self.stop()
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let candidates = results.compactMap { result -> (MacConnectionModel.Device, NWEndpoint)? in
                guard case .service(let name, let type, let domain, let interface) = result.endpoint else { return nil }
                let device = MacConnectionModel.Device(
                    id: "\(name).\(type).\(domain)@\(interface?.name ?? "")",
                    name: name,
                    meetingCopyProbeHint: Self.meetingCopyHint(result.metadata),
                    automaticSyncProbeHint: Self.automaticSyncHint(result.metadata),
                    automaticSyncResourcesProbeHint: Self.automaticSyncResourcesHint(result.metadata)
                )
                return (device, result.endpoint)
            }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                let unique = Dictionary(candidates.map { ($0.0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.endpoints = unique.mapValues(\.1)
                for (_, endpoint) in unique.values {
                    MacNetworkDiagnostics.endpoint(endpoint, event: "discovered", generation: generation)
                }
                let devices = unique.values.map(\.0).sorted { $0.id < $1.id }
                self.onUpdate?(.devices(devices))
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        MacNetworkDiagnostics.logger.info("event=discovery-stop generation=\(self.generation.uuidString, privacy: .public)")
        generation = UUID()
        browser?.cancel()
        browser = nil
        endpoints = [:]
    }

    func endpoint(for deviceID: String) -> NWEndpoint? { endpoints[deviceID] }

    nonisolated private static func meetingCopyHint(_ metadata: NWBrowser.Result.Metadata) -> Bool {
        guard case .bonjour(let record) = metadata else { return false }
        // A spoofable discovery hint, never capability acceptance or an identity.
        return record["meeting-copy"] == "2"
    }

    nonisolated static func automaticSyncHint(_ metadata: NWBrowser.Result.Metadata) -> Bool {
        guard case .bonjour(let record) = metadata else { return false }
        return record["automatic-sync"] == "1"
    }

    nonisolated static func automaticSyncResourcesHint(_ metadata: NWBrowser.Result.Metadata) -> Bool {
        guard case .bonjour(let record) = metadata else { return false }
        return record["automatic-sync-resources"] == "1"
    }
}
