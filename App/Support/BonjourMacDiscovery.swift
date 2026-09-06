import Foundation
import Network

@MainActor
protocol MacDiscovering: AnyObject {
    var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)? { get set }
    func start()
    func stop()
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
    private var generation = UUID()
    private let queue = DispatchQueue(label: "com.transcript.mac-discovery")

    func start() {
        stop()
        let generation = self.generation
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_vtscribe._tcp", domain: nil),
            using: parameters
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .waiting(let error), .failed(let error):
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
            let devices = results.compactMap { result -> MacConnectionModel.Device? in
                guard case .service(let name, let type, let domain, let interface) = result.endpoint else { return nil }
                return .init(
                    id: "\(name).\(type).\(domain)@\(interface?.name ?? "")",
                    name: name
                )
            }.sorted { $0.id < $1.id }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.onUpdate?(.devices(devices))
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
    }
}
