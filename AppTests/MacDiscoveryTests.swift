import XCTest
import Network
@testable import Transcript

@MainActor
final class MacDiscoveryTests: XCTestCase {
    func testSameInterfaceUnequalPathsPassProductionMonitorFilter() async throws {
        let (first, second) = try await loopbackPaths()
        func oldSignature(_ path: NWPath) -> String {
            "\(path.status):" + path.availableInterfaces.map {
                "\($0.index):\($0.type):\(path.usesInterfaceType($0.type))"
            }.sorted().joined(separator: ",")
        }
        XCTAssertEqual(oldSignature(first), oldSignature(second))
        XCTAssertNotEqual(first, second, "Different loopback endpoints must provide distinct real path snapshots")
        let discovery = BonjourMacDiscovery()
        XCTAssertFalse(discovery.networkPathDidChange(first))
        XCTAssertFalse(discovery.networkPathDidChange(first))
        XCTAssertTrue(discovery.networkPathDidChange(second),
                      "The production monitor filter must not discard changed paths on the same interface")
        XCTAssertFalse(discovery.networkPathDidChange(second))
    }

    func testNetworkPathFilterTracksUnavailableAndResetsBaseline() async throws {
        let (satisfied, _) = try await loopbackPaths()
        let unavailable = NWPathMonitor().currentPath
        XCTAssertNotEqual(unavailable.status, .satisfied)
        let discovery = BonjourMacDiscovery()
        XCTAssertFalse(discovery.networkPathDidChange(satisfied))
        XCTAssertFalse(discovery.networkPathDidChange(unavailable))
        XCTAssertFalse(discovery.networkPathDidChange(unavailable))
        XCTAssertTrue(discovery.networkPathDidChange(satisfied))
        discovery.stopMonitoringNetwork()
        XCTAssertFalse(discovery.networkPathDidChange(satisfied),
                       "A new monitor generation starts with a baseline, not a recovery request")
    }

    private func loopbackPaths() async throws -> (NWPath, NWPath) {
        let firstServer = try PairingTCPFixture { try await $0.waitForClose() }
        let secondServer = try PairingTCPFixture { try await $0.waitForClose() }
        defer { firstServer.stop(); secondServer.stop() }
        let first = NWConnection(to: try await firstServer.start(), using: .tcp)
        let second = NWConnection(to: try await secondServer.start(), using: .tcp)
        defer { first.cancel(); second.cancel() }
        let queue = DispatchQueue(label: "transcript.test.discovery-paths")
        first.start(queue: queue)
        second.start(queue: queue)
        try await pairingEventually {
            guard case .ready = first.state, case .ready = second.state else { return false }
            return first.currentPath?.status == .satisfied && second.currentPath?.status == .satisfied
        }
        return (try XCTUnwrap(first.currentPath), try XCTUnwrap(second.currentPath))
    }

    func testRealBonjourTXTCapabilitiesRefreshAndRestartWithoutStaleCallbacks() async throws {
        let configuration = try TestStorageConfiguration.resolve()
        let runID = try XCTUnwrap(configuration.runID)
        let root = try XCTUnwrap(configuration.applicationSupportDirectory())
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(environment[TestStorageConfiguration.storageKey], "1")
        XCTAssertEqual(root.lastPathComponent, runID.uuidString)
        if let expected = environment["TRANSCRIPT_QA_EXPECTED_RUN_ID"] {
            XCTAssertEqual(runID.uuidString, expected)
        }
        XCTAssertFalse(UIFixture.isRequested)
        print("BONJOUR_TXT_ISOLATION runID=\(runID.uuidString) storage=1 root=\(root.path)")

        let prefix = "Transcript-TXT-\(UUID().uuidString)"
        let names = ["\(prefix)-supported", "\(prefix)-absent", "\(prefix)-wrong"]
        let records: [Data?] = [
            NetService.data(fromTXTRecord: ["meeting-copy": Data("2".utf8), "automatic-sync": Data("1".utf8)]),
            nil,
            NetService.data(fromTXTRecord: ["meeting-copy": Data("1".utf8), "automatic-sync": Data("2".utf8)])
        ]
        let listeners = try names.map { _ in try NWListener(using: .tcp, on: .any) }
        defer { listeners.forEach { $0.cancel() } }
        let ready = expectation(description: "All isolated Bonjour advertisers are ready")
        ready.expectedFulfillmentCount = listeners.count
        for (index, listener) in listeners.enumerated() {
            listener.service = NWListener.Service(
                name: names[index], type: "_vtscribe._tcp", txtRecord: records[index]
            )
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.fulfill()
                case .failed(let error): XCTFail("Local Bonjour advertiser failed: \(error)")
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "\(prefix).advertiser.\(index)"))
        }
        await fulfillment(of: [ready], timeout: 10)
        for listener in listeners { XCTAssertNotNil(listener.port) }

        let discovery = BonjourMacDiscovery()
        defer {
            discovery.stop()
            discovery.onUpdate = nil
        }
        var candidates: [MacConnectionModel.Device] = []
        var observed: (([MacConnectionModel.Device]) -> Void)?
        discovery.onUpdate = { update in
            switch update {
            case .devices(let devices):
                candidates = devices.filter { names.contains($0.name) }
                observed?(candidates)
            case .permissionDenied:
                XCTFail("Local Network permission denied; real discovery is required")
            case .failed(let error):
                XCTFail("Real Bonjour discovery failed: \(error)")
            }
        }
        let found = expectation(description: "Production discovery found all real test advertisements")
        found.assertForOverFulfill = false
        observed = { devices in
            if Set(devices.map(\.name)) == Set(names) { found.fulfill() }
        }
        discovery.start()
        await fulfillment(of: [found], timeout: 20)
        let supported = try XCTUnwrap(candidates.first { $0.name == names[0] })
        XCTAssertTrue(supported.meetingCopyProbeHint, "Actual meeting-copy=2 TXT must enable the discovery hint")
        for device in candidates {
            XCTAssertEqual(device.meetingCopyProbeHint, device.name == names[0])
            XCTAssertEqual(device.automaticSyncProbeHint, device.name == names[0],
                           "Only the exact new protocol TXT hint may permit its authenticated probe")
            guard case .service(let name, let type, let domain, let interface) = discovery.endpoint(for: device.id) else {
                return XCTFail("The actual discovered Network endpoint must be retained")
            }
            XCTAssertEqual(name, device.name)
            XCTAssertEqual(type, "_vtscribe._tcp")
            XCTAssertEqual(device.id, "\(name).\(type).\(domain)@\(interface?.name ?? "")",
                           "Retain the actual Bonjour interface scope; do not silently strip it")
        }
        guard supported.meetingCopyProbeHint else { return }

        let refreshed = expectation(description: "An actual TXT change refreshes the existing candidate")
        refreshed.assertForOverFulfill = false
        observed = { devices in
            if let device = devices.first(where: { $0.id == supported.id }),
               !device.meetingCopyProbeHint {
                refreshed.fulfill()
            }
        }
        listeners[0].service = NWListener.Service(
            name: names[0], type: "_vtscribe._tcp", txtRecord: records[2]
        )
        await fulfillment(of: [refreshed], timeout: 20)

        let upgraded = expectation(description: "Restoring TXT version 2 refreshes the same candidate")
        upgraded.assertForOverFulfill = false
        observed = { devices in
            if let device = devices.first(where: { $0.id == supported.id }),
               device.meetingCopyProbeHint {
                upgraded.fulfill()
            }
        }
        listeners[0].service = NWListener.Service(
            name: names[0], type: "_vtscribe._tcp", txtRecord: records[0]
        )
        await fulfillment(of: [upgraded], timeout: 20)

        let supportPublished = expectation(description: "A fresh real browser independently observes TXT version 2")
        supportPublished.assertForOverFulfill = false
        let removalPublished = expectation(description: "A fresh real browser observes the removed TXT key")
        removalPublished.assertForOverFulfill = false
        let observer = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_vtscribe._tcp", domain: nil), using: .tcp
        )
        defer { observer.cancel() }
        let supportedName = names[0]
        var observerSawSupported = false
        let observeVersion: @MainActor @Sendable (String?) -> Void = { version in
            if version == "2" {
                observerSawSupported = true
                supportPublished.fulfill()
            } else if version == nil, observerSawSupported {
                removalPublished.fulfill()
            }
        }
        observer.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      name == supportedName else { continue }
                let version: String?
                switch result.metadata {
                case .bonjour(let record): version = record["meeting-copy"]
                case .none: version = nil
                @unknown default: continue
                }
                print("BONJOUR_TXT_FRESH_OBSERVER metadata=\(result.metadata) meeting-copy=\(version ?? "absent")")
                Task { @MainActor in observeVersion(version) }
            }
        }
        observer.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error), .failed(let error):
                XCTFail("Fresh real TXT observer failed: \(error)")
            default: break
            }
        }
        observer.start(queue: DispatchQueue(label: "\(prefix).fresh-observer"))
        await fulfillment(of: [supportPublished], timeout: 20)

        let oldIDs = candidates.map(\.id)
        let stale = expectation(description: "Stopped discovery must not deliver queued callbacks")
        stale.isInverted = true
        discovery.onUpdate = { _ in stale.fulfill() }
        // Queue a real advertisement change immediately before stopping the browser.
        listeners[0].service = NWListener.Service(name: names[0], type: "_vtscribe._tcp")
        discovery.stop()
        for id in oldIDs { XCTAssertNil(discovery.endpoint(for: id)) }
        await fulfillment(of: [stale], timeout: 2)
        for id in oldIDs { XCTAssertNil(discovery.endpoint(for: id)) }

        await fulfillment(of: [removalPublished], timeout: 20)
        for id in oldIDs { XCTAssertNil(discovery.endpoint(for: id)) }

        let restarted = expectation(description: "Restart converges to the independently observed current TXT")
        restarted.assertForOverFulfill = false
        discovery.onUpdate = { update in
            switch update {
            case .devices(let devices):
                let current = devices.filter { names.contains($0.name) }
                guard Set(current.map(\.name)) == Set(names) else { return }
                for device in current {
                    XCTAssertNotNil(discovery.endpoint(for: device.id))
                    if device.name != supportedName { XCTAssertFalse(device.meetingCopyProbeHint) }
                }
                // A new browser can initially receive cached DNS records, not old-generation callbacks.
                guard current.allSatisfy({ !$0.meetingCopyProbeHint }) else { return }
                print("BONJOUR_TXT_RESTART converged to absent/absent/wrong-version hints=false")
                restarted.fulfill()
            case .permissionDenied:
                XCTFail("Local Network permission denied after restart")
            case .failed(let error):
                XCTFail("Real Bonjour restart failed: \(error)")
            }
        }
        discovery.start()
        await fulfillment(of: [restarted], timeout: 20)
        discovery.stop()
        for id in oldIDs { XCTAssertNil(discovery.endpoint(for: id)) }
    }

    func testRealBonjourBrowserFindsPublishedService() async throws {
        let name = "Transcript-test-\(UUID().uuidString)"
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: name, type: "_vtscribe._tcp")
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "Bonjour listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: DispatchQueue(label: "transcript.test-advertiser"))
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let discovery = BonjourMacDiscovery()
        let found = expectation(description: "Real browser received the published service")
        found.assertForOverFulfill = false
        var discoveredDeviceID: String?
        discovery.onUpdate = { update in
            if case .devices(let devices) = update, let device = devices.first(where: { $0.name == name }) {
                guard let endpoint = discovery.endpoint(for: device.id),
                      case .service(let discoveredName, let type, _, _) = endpoint else {
                    return XCTFail("A discovered candidate must retain its real Network endpoint")
                }
                XCTAssertEqual(discoveredName, name)
                XCTAssertEqual(type, "_vtscribe._tcp")
                discoveredDeviceID = device.id
                found.fulfill()
            }
        }
        discovery.start()
        defer { discovery.stop() }
        await fulfillment(of: [found], timeout: 15)
        let deviceID = try XCTUnwrap(discoveredDeviceID)
        discovery.stop()
        XCTAssertNil(discovery.endpoint(for: deviceID))
    }

    func testFindMacStartsServiceAndDoesNotClaimAuthenticatedConnection() async {
        let discovery = DiscoveryProbe()
        let model = MacConnectionModel(discovery: discovery)
        XCTAssertTrue(model.canDiscover)
        XCTAssertFalse(model.hasTransportActions)
        await model.perform(.discover)
        XCTAssertEqual(discovery.starts, 1)
        XCTAssertEqual(model.connection, .discovering)
        let device = MacConnectionModel.Device(id: "candidate", name: "Office Mac")
        discovery.onUpdate?(.devices([device]))
        XCTAssertEqual(model.devices, [device])
        XCTAssertFalse(model.isConnected)
        XCTAssertNotNil(model.submissionBlockReason(meetingID: "meeting"))
        await model.perform(.selectDevice(device.id))
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(model.jobs.isEmpty)
        model.stopDiscovery()
        discovery.onUpdate?(.devices([]))
        XCTAssertEqual(model.devices, [device], "Late events cannot mutate a stopped search")
    }

    func testPermissionDeniedIsActionableAndRetryStartsNewSearch() async {
        let discovery = DiscoveryProbe()
        let model = MacConnectionModel(discovery: discovery)
        await model.perform(.discover)
        discovery.onUpdate?(.permissionDenied)
        XCTAssertTrue(model.localNetworkDenied)
        XCTAssertFalse(model.isConnecting)
        guard case .failed = model.connection else { return XCTFail("Permission refusal must not spin forever") }
        await model.perform(.retryConnection)
        XCTAssertEqual(discovery.starts, 2)
        XCTAssertFalse(model.localNetworkDenied)
        XCTAssertEqual(model.connection, .discovering)
        model.stopDiscovery()
    }

    func testNetworkFailureCanBeRetriedAndOldResultsAreCleared() async {
        let discovery = DiscoveryProbe()
        let model = MacConnectionModel(discovery: discovery)
        await model.perform(.discover)
        discovery.onUpdate?(.devices([.init(id: "old", name: "Old Mac")]))
        discovery.onUpdate?(.failed("Network unavailable"))
        XCTAssertEqual(model.connection, .failed(reason: "Network unavailable"))
        await model.perform(.discover)
        XCTAssertTrue(model.devices.isEmpty)
        model.stopDiscovery()
    }

    func testPairingConnectionDoesNotEnableMeetingTransfer() {
        let model = MacConnectionModel()
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        model.connection = .connected(.init(id: "verified-key", name: "Paired Mac"), modelReady: true)
        XCTAssertTrue(model.isConnected)
        XCTAssertFalse(model.supportsMeetingTransfer)
        for language in [AppLanguage.en, .zhHans] {
            localization.language = language
            let reason = model.submissionBlockReason(meetingID: "meeting")
            XCTAssertNotNil(reason)
            XCTAssertTrue(model.jobs.isEmpty)
            XCTAssertEqual(
                reason,
                language == .en
                    ? "Receiving is not advertised. It may be turned off on the Mac, the Mac version may be older, or discovery may be stale. Check receiving, then discover and reconnect; update the Mac if needed."
                    : "未发现接收功能的广播。可能是 Mac 关闭了接收、版本较旧，或发现信息已过期。请检查接收设置，然后重新查找并连接；必要时更新 Mac。"
            )
        }
    }

    func testLeavingConnectionPresentationDoesNotEraseEstablishedState() {
        let model = MacConnectionModel(discovery: DiscoveryProbe())
        let state = MacConnectionModel.Connection.connected(.init(id: "verified-key", name: "Mac"), modelReady: nil)
        model.connection = state
        model.endConnectionPresentation()
        XCTAssertEqual(model.connection, state)
    }
}

@MainActor
private final class DiscoveryProbe: MacDiscovering {
    var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)?
    var starts = 0
    func endpoint(for deviceID: String) -> NWEndpoint? { nil }
    func start() { starts += 1 }
    func stop() {}
}
