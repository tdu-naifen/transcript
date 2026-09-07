import Network
import XCTest
@testable import TranscriptMac

@MainActor
final class MacBonjourServiceTests: XCTestCase {
    func testSleepStopsAdvertisingAndWakeRestoresOnlyEnabledDiscovery() {
        var creations = 0
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac") { _ in
            creations += 1
            return listener
        }
        service.start()
        listener.emit(.ready)
        listener.emit(.registered("Office Mac"))
        service.suspendForSleep()
        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(service.isSuspended)
        XCTAssertNil(service.advertisedName)
        XCTAssertFalse(service.pairing.isConnected)
        service.recoverIfNeeded()
        XCTAssertEqual(creations, 1)
        service.resumeAfterWake()
        XCTAssertFalse(service.isSuspended)
        XCTAssertEqual(creations, 2)
        XCTAssertFalse(service.pairing.allowsNewPairing)
        service.suspendForSleep()
        service.stop()
        service.resumeAfterWake()
        XCTAssertEqual(creations, 2)
        XCTAssertFalse(service.isEnabled)
    }

    func testSleepWakeDoesNotRetryDeniedNetworkPermission() {
        var creations = 0
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac") { _ in
            creations += 1
            return listener
        }
        service.start()
        defer { service.stop() }
        listener.emit(.failed(.network(.dns(-65570))))
        service.suspendForSleep()
        service.resumeAfterWake()
        XCTAssertTrue(service.localNetworkDenied)
        XCTAssertEqual(creations, 1)
    }

    func testQABundleIdentifiesFixedTransferCodec() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "TranscriptMeetingCopyProtocolRevision") as? String,
            "5d61b80f84052897e476b5ff8c1c15f0648e410a"
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "TranscriptMeetingCopyChunkBytes") as? Int,
            MeetingCopyWire.chunkLimit
        )
    }

    func testEnabledDiscoveryRestoresWithoutOpeningNewPairingAndStopPersists() throws {
        let suite = "MacBonjourRestore-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = BonjourListenerProbe()
        var original: MacBonjourService? = MacBonjourService(
            serviceName: "Office Mac", preferences: preferences
        ) { _ in first }
        original?.start()
        XCTAssertTrue(original?.pairing.allowsNewPairing == true)
        original = nil
        XCTAssertEqual(first.cancels, 1)

        let second = BonjourListenerProbe()
        let restored = MacBonjourService(serviceName: "Office Mac", preferences: preferences) { _ in second }
        restored.restoreDiscovery()
        restored.restoreDiscovery()
        XCTAssertEqual(second.starts, 1)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertFalse(restored.pairing.allowsNewPairing)
        restored.stop()

        let third = BonjourListenerProbe()
        let stopped = MacBonjourService(serviceName: "Office Mac", preferences: preferences) { _ in third }
        stopped.restoreDiscovery()
        stopped.recoverIfNeeded()
        XCTAssertEqual(third.starts, 0)
        XCTAssertFalse(stopped.isEnabled)
    }

    func testTransientFailureAutomaticallyReplacesListenerWithoutNewPairing() async throws {
        let old = BonjourListenerProbe()
        let replacement = BonjourListenerProbe()
        var attempts = 0
        let service = MacBonjourService(serviceName: "Office Mac", recoveryDelay: .milliseconds(10)) { _ in
            attempts += 1
            return attempts == 1 ? old : replacement
        }
        service.start()
        defer { service.stop() }
        old.emit(.failed(.network(.posix(.ENETDOWN))))
        for _ in 0..<100 where replacement.starts == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(replacement.starts, 1)
        XCTAssertFalse(service.pairing.allowsNewPairing)
        old.emit(.cancelled)
        XCTAssertEqual(service.state, .starting)
        replacement.emit(.ready)
        replacement.emit(.registered("Recovered Mac"))
        XCTAssertEqual(service.state, .advertising)
        XCTAssertNil(service.pairing.connectedPeer, "Discovery must not claim an authenticated connection")
    }

    func testStopCancelsPendingAutomaticRecovery() async throws {
        var attempts = 0
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac", recoveryDelay: .milliseconds(10)) { _ in
            attempts += 1
            return listener
        }
        service.start()
        listener.emit(.failed(.network(.posix(.ENETDOWN))))
        service.stop()
        try await Task.sleep(for: .milliseconds(80))
        service.recoverIfNeeded()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(service.state, .idle)
    }

    func testPermissionDenialDoesNotAutomaticallyRetry() async throws {
        var attempts = 0
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac", recoveryDelay: .milliseconds(10)) { _ in
            attempts += 1
            return listener
        }
        service.start()
        defer { service.stop() }
        listener.emit(.failed(.network(.dns(-65570))))
        service.recoverIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(service.localNetworkDenied)
    }

    func testWakeRecoveryPreservesHealthyListenerAndReplacesWaitingListener() {
        let old = BonjourListenerProbe()
        let replacement = BonjourListenerProbe()
        var attempts = 0
        let service = MacBonjourService(serviceName: "Office Mac") { _ in
            attempts += 1
            return attempts == 1 ? old : replacement
        }
        service.start()
        defer { service.stop() }
        old.emit(.ready)
        old.emit(.registered("Office Mac"))
        service.recoverIfNeeded()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(old.cancels, 0)
        old.emit(.waiting(.network(.posix(.ENETDOWN))))
        service.recoverIfNeeded()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(old.cancels, 1)
        XCTAssertFalse(service.pairing.allowsNewPairing)
    }

    func testInitializationDoesNotPublishAndStartIsIdempotent() {
        let listener = BonjourListenerProbe()
        var requestedNames: [String] = []
        let service = MacBonjourService(serviceName: "  Office Mac  ") { name in
            requestedNames.append(name)
            return listener
        }

        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.advertisedName)
        XCTAssertTrue(requestedNames.isEmpty)
        service.start()
        service.start()
        XCTAssertEqual(requestedNames, ["Office Mac"])
        XCTAssertEqual(listener.starts, 1)
        XCTAssertEqual(service.state, .starting)
        service.stop()
    }

    func testAdvertisingRequiresBothListenerReadinessAndRegistrationAndTracksRename() {
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac") { _ in listener }
        service.start()
        listener.emit(.ready)
        XCTAssertEqual(service.state, .starting, "A listening socket is not a Bonjour registration")
        XCTAssertNil(service.advertisedName)
        listener.emit(.registered("Office Mac (2)"))
        XCTAssertEqual(service.state, .advertising)
        XCTAssertEqual(service.advertisedName, "Office Mac (2)")
        listener.emit(.registered("Office Mac (3)"))
        listener.emit(.unregistered("Office Mac (2)"))
        XCTAssertEqual(service.advertisedName, "Office Mac (3)")
        listener.emit(.unregistered("Office Mac (3)"))
        XCTAssertNil(service.advertisedName)
        XCTAssertEqual(service.state, .starting)
        service.stop()
    }

    func testRegistrationBeforeReadyDoesNotClaimAdvertising() {
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac") { _ in listener }
        service.start()
        listener.emit(.registered("Office Mac"))
        XCTAssertEqual(service.state, .starting)
        XCTAssertNil(service.advertisedName)
        listener.emit(.ready)
        XCTAssertEqual(service.state, .advertising)
        service.stop()
    }

    func testStopInvalidatesAllLateCallbacksAndIsIdempotent() {
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac") { _ in listener }
        service.start()
        service.stop()
        service.stop()
        listener.emit(.ready)
        listener.emit(.registered("Late Mac"))
        listener.emit(.failed(.network(.dns(-65570))))
        listener.emit(.cancelled)
        XCTAssertEqual(listener.cancels, 1)
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.advertisedName)
        XCTAssertFalse(service.localNetworkDenied)
    }

    func testRetryReplacesListenerAndIgnoresOldGeneration() {
        let old = BonjourListenerProbe()
        let replacement = BonjourListenerProbe()
        var creations = 0
        let service = MacBonjourService(serviceName: "Office Mac") { _ in
            creations += 1
            return creations == 1 ? old : replacement
        }
        service.start()
        old.emit(.ready)
        old.emit(.registered("Old Mac"))
        service.retry()
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(replacement.starts, 1)
        XCTAssertEqual(service.state, .starting)
        XCTAssertNil(service.advertisedName)
        old.emit(.registered("Stale Mac"))
        old.emit(.cancelled)
        old.emit(.waiting(.network(.dns(-65570))))
        XCTAssertEqual(service.state, .starting)
        replacement.emit(.registered("New Mac"))
        replacement.emit(.ready)
        XCTAssertEqual(service.advertisedName, "New Mac")
        XCTAssertEqual(service.state, .advertising)
        service.stop()
    }

    func testWaitingCanRecoverButLocalNetworkDenialFailsActionably() {
        let listener = BonjourListenerProbe()
        let service = MacBonjourService(serviceName: "Office Mac") { _ in listener }
        service.start()
        listener.emit(.registered("Office Mac"))
        listener.emit(.ready)
        let offline = MacBonjourService.Failure.network(.posix(.ENETDOWN))
        listener.emit(.waiting(offline))
        XCTAssertEqual(service.state, .waiting(offline))
        XCTAssertNil(service.advertisedName)
        XCTAssertEqual(listener.cancels, 0)
        listener.emit(.ready)
        XCTAssertEqual(service.state, .advertising)
        listener.emit(.waiting(.network(.dns(-65570))))
        guard case .failed(let failure) = service.state else {
            return XCTFail("Permission denial must not leave discovery spinning")
        }
        XCTAssertTrue(service.localNetworkDenied)
        XCTAssertTrue(failure.message.contains("System Settings"))
        XCTAssertTrue(failure.message.contains("Local Network"))
        XCTAssertEqual(listener.cancels, 1)
        listener.emit(.ready)
        XCTAssertEqual(service.state, .failed(failure))
        service.stop()
    }

    func testConstructionFailureCanRetryAndNetworkFailureCancels() {
        let listener = BonjourListenerProbe()
        var attempts = 0
        let service = MacBonjourService(serviceName: "Office Mac") { _ in
            attempts += 1
            if attempts == 1 { throw NWError.posix(.EADDRINUSE) }
            return listener
        }
        service.start()
        guard case .failed = service.state else { return XCTFail("Expected creation failure") }
        service.retry()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(service.state, .starting)
        let failure = MacBonjourService.Failure.network(.posix(.ENETDOWN))
        listener.emit(.failed(failure))
        XCTAssertEqual(service.state, .failed(failure))
        XCTAssertEqual(listener.cancels, 1)
        XCTAssertNil(service.advertisedName)
        service.stop()
    }

    func testPermissionDeniedRetryClearsErrorAndUnexpectedCancellationFails() {
        let old = BonjourListenerProbe()
        let replacement = BonjourListenerProbe()
        var attempts = 0
        let service = MacBonjourService(serviceName: "Office Mac") { _ in
            attempts += 1
            return attempts == 1 ? old : replacement
        }
        service.start()
        old.emit(.failed(.network(.dns(-65570))))
        XCTAssertTrue(service.localNetworkDenied)
        service.retry()
        XCTAssertFalse(service.localNetworkDenied)
        XCTAssertEqual(service.state, .starting)
        replacement.emit(.cancelled)
        guard case .failed(let failure) = service.state else {
            return XCTFail("Unexpected cancellation must not leave the UI advertising")
        }
        XCTAssertTrue(failure.message.contains("Retry"))
        XCTAssertEqual(replacement.cancels, 1)
        service.stop()
    }

    func testReleasingServiceCancelsOwnedListener() {
        let listener = BonjourListenerProbe()
        var service: MacBonjourService? = MacBonjourService(serviceName: "Office Mac") { _ in listener }
        weak var reference = service
        service?.start()
        service = nil
        XCTAssertNil(reference)
        XCTAssertEqual(listener.cancels, 1)
        listener.emit(.registered("Late Mac"))
    }

    func testServiceNamesAreNonemptyAndFitBonjourUTF8Label() {
        let blank = MacBonjourService(serviceName: " \n ")
        XCTAssertEqual(blank.serviceName, "Transcript Mac")
        let unicode = MacBonjourService(serviceName: String(repeating: "電", count: 64))
        XCTAssertLessThanOrEqual(unicode.serviceName.utf8.count, 63)
        XCTAssertFalse(unicode.serviceName.isEmpty)
    }

    func testLocalizedFailureFormatsPreserveUnderlyingErrorDetails() {
        let error = NSError(
            domain: "BonjourTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Port is 100% unavailable"]
        )
        let service = MacBonjourService(serviceName: "Office Mac") { _ in throw error }
        service.start()
        guard case .failed(let failure) = service.state else { return XCTFail("Expected failure") }
        XCTAssertTrue(failure.message.contains(error.localizedDescription))
        XCTAssertFalse(failure.message.contains("%@"))
        XCTAssertFalse(service.connectionExplanation.isEmpty)

        let networkError = NWError.posix(.ENETDOWN)
        let networkFailure = MacBonjourService.Failure.network(networkError)
        XCTAssertTrue(networkFailure.message.contains(networkError.localizedDescription))
        XCTAssertFalse(networkFailure.message.contains("%@"))
        service.stop()
    }

    func testRealBrowserDiscoversServiceTimesOutUnauthenticatedConnectionsAndObservesWithdrawal() async throws {
        let name = "TranscriptMac-test-\(UUID().uuidString)"
        let service = MacBonjourService(serviceName: name, preferences: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: MacBonjourService.serviceType, domain: nil),
            using: parameters
        )
        let found = expectation(description: "Browser discovers the Mac advertisement")
        let removed = expectation(description: "Browser observes withdrawal after stop")
        let results = BrowserResultsProbe(name: name, found: found, removed: removed)
        let queue = DispatchQueue(label: "com.transcript.mac-bonjour-test")
        browser.browseResultsChangedHandler = { entries, _ in results.update(entries) }
        browser.start(queue: queue)
        service.start()
        defer {
            service.stop()
            browser.cancel()
        }

        await fulfillment(of: [found], timeout: 15)
        // Service callbacks and browser callbacks arrive on different queues.
        for _ in 0..<100 where service.state != .advertising {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(service.state, .advertising)
        XCTAssertEqual(service.advertisedName, name)

        let rejected = expectation(description: "Silent unauthenticated TCP attempt expires without data")
        rejected.assertForOverFulfill = false
        let connected = expectation(description: "Discovered Bonjour endpoint establishes TCP")
        connected.assertForOverFulfill = false
        let endpoint = try XCTUnwrap(queue.sync { results.endpoint })
        let connection = NWConnection(
            to: endpoint,
            using: parameters
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connected.fulfill()
                // Send nothing. The handshake deadline closes the socket without sending private data.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                    XCTAssertTrue(data?.isEmpty ?? true, "A silent peer must not receive application data")
                    XCTAssertTrue(complete || error != nil)
                    rejected.fulfill()
                }
            case .failed(let error):
                XCTFail("Could not connect to discovered endpoint: \(error)")
                connected.fulfill()
                rejected.fulfill()
            default:
                break
            }
        }
        connection.start(queue: queue)
        defer {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        await fulfillment(of: [connected], timeout: 15)
        guard case .ready = connection.state else {
            XCTFail("Bonjour discovery succeeded, but TCP did not become ready (\(connection.state)). This is a pre-handshake connectivity failure: inspect the macOS incoming-connections Firewall prompt and the separate Local Network permission. Do not disable the firewall.")
            return
        }
        for _ in 0..<200 where service.pairing.state != .negotiating {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard service.pairing.state == .negotiating else {
            XCTFail("TCP opened but the listener did not admit a pairing session (\(service.pairing.state)); the protocol deadline has not started. Check the pending macOS Firewall incoming-connections prompt and Local Network permission.")
            return
        }
        await fulfillment(of: [rejected], timeout: 12)
        XCTAssertEqual(service.state, .advertising, "A TCP attempt is not an authenticated connection")
        queue.sync { results.expectRemoval() }
        service.stop()
        await fulfillment(of: [removed], timeout: 10)
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.advertisedName)
    }
}

@MainActor
private final class BonjourListenerProbe: MacBonjourListening {
    private var onEvent: (@MainActor @Sendable (MacBonjourListenerEvent) -> Void)?
    private(set) var starts = 0
    private(set) var cancels = 0

    func start(onEvent: @escaping @MainActor @Sendable (MacBonjourListenerEvent) -> Void) {
        starts += 1
        self.onEvent = onEvent
    }

    // Retain the callback deliberately to simulate already-enqueued Network events.
    func cancel() { cancels += 1 }
    func emit(_ event: MacBonjourListenerEvent) { onEvent?(event) }
}

/// Accessed exclusively by the browser's serial callback queue.
private final class BrowserResultsProbe: @unchecked Sendable {
    let name: String
    let found: XCTestExpectation
    let removed: XCTestExpectation
    private var wasFound = false
    private var wasRemoved = false
    private var expectingRemoval = false
    private(set) var endpoint: NWEndpoint?

    init(name: String, found: XCTestExpectation, removed: XCTestExpectation) {
        self.name = name
        self.found = found
        self.removed = removed
    }

    func expectRemoval() { expectingRemoval = true }

    func update(_ results: Set<NWBrowser.Result>) {
        let present = results.contains {
            if case .service(let candidate, _, _, _) = $0.endpoint { return candidate == name }
            return false
        }
        endpoint = results.first {
            if case .service(let candidate, _, _, _) = $0.endpoint { return candidate == name }
            return false
        }?.endpoint
        if present, !wasFound {
            wasFound = true
            found.fulfill()
        } else if !present, wasFound, !wasRemoved, expectingRemoval {
            wasRemoved = true
            removed.fulfill()
        }
    }
}
