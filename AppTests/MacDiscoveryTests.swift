import XCTest
import Network
@testable import Transcript

@MainActor
final class MacDiscoveryTests: XCTestCase {
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
        discovery.onUpdate = { update in
            if case .devices(let devices) = update, devices.contains(where: { $0.name == name }) {
                found.fulfill()
            }
        }
        discovery.start()
        defer { discovery.stop() }
        await fulfillment(of: [found], timeout: 15)
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
}

@MainActor
private final class DiscoveryProbe: MacDiscovering {
    var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)?
    var starts = 0
    func start() { starts += 1 }
    func stop() {}
}
