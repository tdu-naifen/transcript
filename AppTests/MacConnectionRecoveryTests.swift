import CryptoKit
import GRDB
import Network
import SwiftUI
import TranscriptCore
import XCTest
@testable import Transcript

@MainActor
final class MacConnectionRecoveryTests: XCTestCase {
    private let timing = MacConnectionModel.RecoveryTiming(discoveryWindow: 0.3, backoff: [0, 0.1, 0.2])
    private let timeouts = IOSMacPairingClient.Timeouts(initial: 0.2, approval: 1, idle: 2, heartbeat: 0.05, pong: 0.2)

    func testForegroundUsesFreshEndpointAndHintsWithoutApprovalOrAutomaticData() async throws {
        let identity = Curve25519.Signing.PrivateKey()
        var applicationMessages = 0
        var heartbeats = 0
        let first = try PairingTCPFixture(identity: identity) { peer in
            try await self.acceptReconnect(
                peer, onHeartbeat: { heartbeats += 1 }, onApplicationMessage: { applicationMessages += 1 }
            )
        }
        let second = try PairingTCPFixture(identity: identity) { peer in
            try await self.acceptReconnect(
                peer, onHeartbeat: { heartbeats += 1 }, onApplicationMessage: { applicationMessages += 1 }
            )
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await first.start(), hint: true)
        let store = PairingStoreProbe()
        store.saved = [first.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: client)
        defer { model.suspendConnection(); first.stop(); second.stop() }

        model.resumeConnection()
        model.resumeConnection()
        try await pairingEventually { model.isConnected }
        XCTAssertEqual(discovery.starts, 1)
        XCTAssertEqual(first.acceptedCount, 1)
        XCTAssertTrue(client.canProbeMeetingTransfer)
        let staleCallback = discovery.onUpdate
        model.suspendConnection()
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(client.canProbeMeetingTransfer)
        XCTAssertFalse(model.supportsMeetingTransfer)
        XCTAssertEqual(store.saved.count, 1)
        discovery.endpointToPublish = try await second.start()
        discovery.device.meetingCopyProbeHint = false
        model.resumeConnection()
        model.resumeConnection()
        staleCallback?(.devices([.init(id: "obsolete", name: "Stale Mac", meetingCopyProbeHint: true)]))
        try await pairingEventually { model.isConnected && second.acceptedCount == 1 }
        XCTAssertEqual(discovery.starts, 2)
        XCTAssertEqual(first.acceptedCount, 1, "Never reconnect using the previous endpoint")
        XCTAssertEqual(model.devices.map(\.id), [discovery.device.id])
        XCTAssertFalse(client.canProbeMeetingTransfer)
        XCTAssertNotNil(model.submissionBlockReason(meetingID: "local"))
        XCTAssertEqual(store.saveCalls, 0)
        try await Task.sleep(for: .milliseconds(120))
        print("RECOVERY_CALLBACK foreground heartbeats=\(heartbeats) applicationMessages=\(applicationMessages)")
        XCTAssertGreaterThan(heartbeats, 0)
        XCTAssertEqual(applicationMessages, 0, "Resume must not probe capabilities or send queued meeting data")
        XCTAssertTrue(model.jobs.isEmpty)
    }

    func testObservedDisconnectDiscoversRestartedMacAtNewEndpoint() async throws {
        let identity = Curve25519.Signing.PrivateKey()
        var firstPeer: PairingTestPeer?
        let first = try PairingTCPFixture(identity: identity) { peer in
            firstPeer = peer
            try await self.acceptReconnect(peer, onHeartbeat: {}, onApplicationMessage: {})
        }
        let restarted = try PairingTCPFixture(identity: identity) { peer in
            try await self.acceptReconnect(peer, onHeartbeat: {}, onApplicationMessage: {})
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await first.start())
        let store = PairingStoreProbe()
        store.saved = [first.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: client)
        defer { model.suspendConnection(); first.stop(); restarted.stop() }
        model.resumeConnection()
        try await pairingEventually { model.isConnected }
        // Let the successful single-flight retire before simulating remote EOF.
        try await Task.sleep(for: .milliseconds(80))
        discovery.endpointToPublish = try await restarted.start()
        firstPeer?.transport.cancel()
        try await pairingEventually { restarted.acceptedCount == 1 && model.isConnected }
        XCTAssertEqual(discovery.starts, 2)
        XCTAssertEqual(first.acceptedCount, 1)
        XCTAssertEqual(store.saveCalls, 0)
    }

    func testReceivingHintRefreshRevokesReadinessAndNeverAutomaticallyProbes() async throws {
        var probes = 0
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake(reconnect: true)
            try await peer.expect("resume")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            while true {
                let inner: MacPairingMessage
                do { inner = try await peer.receive() } catch { return }
                if inner.type == "ping" { try await peer.send(.init(type: "pong")); continue }
                let request = try MeetingCopyWire.message(inner)
                XCTAssertEqual(request.type, .capabilities)
                probes += 1
                var response = MeetingCopyWire.Message(.accepted, requestID: request.requestID)
                response.capability = MeetingCopyWire.capability
                try await peer.send(MeetingCopyWire.inner(response))
            }
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await server.start(), hint: true)
        let store = PairingStoreProbe()
        store.saved = [server.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: client)
        defer { model.suspendConnection(); server.stop() }
        model.resumeConnection()
        try await pairingEventually { model.isConnected }
        XCTAssertEqual(probes, 0)
        try await client.negotiateMeetingCopy()
        XCTAssertTrue(model.supportsMeetingTransfer)
        discovery.device.meetingCopyProbeHint = false
        discovery.publish()
        XCTAssertTrue(model.isConnected)
        XCTAssertFalse(model.supportsMeetingTransfer)
        XCTAssertFalse(client.canProbeMeetingTransfer)
        discovery.device.meetingCopyProbeHint = true
        discovery.publish()
        XCTAssertTrue(client.canProbeMeetingTransfer)
        XCTAssertFalse(model.supportsMeetingTransfer, "TXT is not authenticated capability acceptance")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probes, 1)
    }

    func testPermissionRefusalStopsRetryAndExplicitRetryCanRecover() async throws {
        let server = try PairingTCPFixture { peer in
            try await self.acceptReconnect(peer, onHeartbeat: {}, onApplicationMessage: {})
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await server.start())
        discovery.denied = true
        let store = PairingStoreProbe()
        store.saved = [server.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: client)
        defer { model.suspendConnection(); server.stop() }
        model.resumeConnection()
        try await pairingEventually { model.localNetworkDenied }
        model.resumeConnection()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(discovery.starts, 1)
        XCTAssertEqual(server.acceptedCount, 0)
        XCTAssertFalse(model.isConnected)
        discovery.denied = false
        await model.perform(.retryConnection)
        try await pairingEventually { model.isConnected }
        XCTAssertEqual(discovery.starts, 2)
        XCTAssertFalse(model.localNetworkDenied)
    }

    func testBoundedOfflineSearchCancelAndUnpairDoNotReviveOldGeneration() async throws {
        for action in [MacConnectionModel.Action.cancelPairing, .unpair] {
            let discovery = RecoveryDiscoveryProbe(endpoint: .hostPort(host: "127.0.0.1", port: 1))
            discovery.publishesDevices = false
            let store = PairingStoreProbe()
            store.saved = [.init(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, name: "Mac", pairedAt: Date())]
            let client = IOSMacPairingClient(store: store, timeouts: timeouts)
            let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
            model.enablePairing(using: client)
            model.resumeConnection()
            try await pairingEventually { discovery.starts == 1 }
            let stale = discovery.onUpdate
            await model.perform(action)
            stale?(.devices([discovery.device]))
            model.resumeConnection()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(discovery.starts, 1)
            XCTAssertFalse(model.isConnected)
            XCTAssertFalse(model.isConnecting)
            XCTAssertEqual(store.identityCalls, 0)
            XCTAssertEqual(store.saved.count, action == .unpair ? 0 : 1)
            model.suspendConnection()
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: .hostPort(host: "127.0.0.1", port: 1))
        discovery.publishesDevices = false
        let store = PairingStoreProbe()
        store.saved = [.init(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, name: "Mac", pairedAt: Date())]
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: IOSMacPairingClient(store: store, timeouts: timeouts))
        model.resumeConnection()
        try await pairingEventually { model.discoveryTimedOut }
        XCTAssertEqual(discovery.starts, 3)
        XCTAssertFalse(model.isConnecting)
        model.resumeConnection()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(discovery.starts, 3)
        model.suspendConnection()
    }

    func testBackgroundCancelsPendingHandshakeAndLateReadyCannotReconnect() async throws {
        var peerReady = false
        var closed = false
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake(reconnect: true)
            try await peer.expect("resume")
            peerReady = true
            try await peer.waitForClose()
            closed = true
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await server.start())
        let store = PairingStoreProbe()
        store.saved = [server.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: client)
        defer { model.suspendConnection(); server.stop() }
        model.resumeConnection()
        try await pairingEventually { peerReady }
        model.suspendConnection()
        try await pairingEventually { closed }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(discovery.starts, 1)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isConnecting)
        XCTAssertEqual(store.saved.count, 1)
    }

    func testUntrustedDiscoveryAndRemovedPinNeverBecomeFirstPairing() async throws {
        let server = try PairingTCPFixture { peer in _ = try await peer.handshake(reconnect: true) }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await server.start())
        let store = PairingStoreProbe()
        let pin = MacPairedDevice(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, name: discovery.device.name, pairedAt: Date())
        store.saved = [pin]
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: .init(discoveryWindow: 0.2, backoff: [0]))
        model.enablePairing(using: client)
        defer { model.suspendConnection(); server.stop() }
        model.resumeConnection()
        try await pairingEventually { client.isFailed }
        XCTAssertFalse(client.isAwaitingApproval)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(store.saved, [pin])
        XCTAssertEqual(store.saveCalls, 0)
        model.suspendConnection()
        store.saved = []
        client.connect(to: discovery.endpointToPublish, requiredPeer: pin)
        XCTAssertTrue(client.isFailed)
        XCTAssertFalse(client.isAwaitingApproval)
        XCTAssertEqual(server.acceptedCount, 1)
    }

    func testForegroundWithoutTrustDoesNotBrowseOrPair() {
        let discovery = RecoveryDiscoveryProbe(endpoint: .hostPort(host: "127.0.0.1", port: 1))
        let store = PairingStoreProbe()
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: IOSMacPairingClient(store: store))
        model.resumeConnection()
        XCTAssertEqual(discovery.starts, 0)
        XCTAssertEqual(store.identityCalls, 0)
        XCTAssertEqual(model.connection, .unpaired)
        model.suspendConnection()
    }

    func testStopSearchingCancelsRecoveryUntilANewForegroundActivation() async throws {
        let discovery = RecoveryDiscoveryProbe(endpoint: .hostPort(host: "127.0.0.1", port: 1))
        discovery.publishesDevices = false
        let store = PairingStoreProbe()
        store.saved = [.init(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, name: "Mac", pairedAt: Date())]
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: IOSMacPairingClient(store: store, timeouts: timeouts))
        defer { model.suspendConnection() }
        model.resumeConnection()
        try await pairingEventually { discovery.starts == 1 }
        let stale = discovery.onUpdate
        model.stopDiscovery()
        stale?(.devices([discovery.device]))
        model.resumeConnection()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(discovery.starts, 1, "Stop searching must cancel all scheduled rounds")
        XCTAssertEqual(store.identityCalls, 0)
        XCTAssertFalse(model.isConnecting)
        model.suspendConnection()
        model.resumeConnection()
        try await pairingEventually { discovery.starts == 2 }
        model.stopDiscovery()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(discovery.starts, 2)
    }

    func testImmediateUnpairSurvivesBackgroundCallerCancellationAndDuplicates() async throws {
        for failsRemoval in [false, true] {
            let store = PairingStoreProbe()
            let pin = MacPairedDevice(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, name: "Mac", pairedAt: Date())
            store.saved = [pin]
            store.failRemove = failsRemoval
            store.onRemove = { XCTAssertFalse(Task.isCancelled, "An accepted unpair must not inherit UI cancellation") }
            let discovery = RecoveryDiscoveryProbe(endpoint: .hostPort(host: "127.0.0.1", port: 1))
            let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
            model.enablePairing(using: IOSMacPairingClient(store: store))
            let intent = Task { await model.perform(.unpair) }
            model.suspendConnection()
            intent.cancel()
            await intent.value
            XCTAssertEqual(store.removeCalls, 1)
            XCTAssertEqual(store.saved, failsRemoval ? [pin] : [])
            XCTAssertEqual(model.actionError != nil, failsRemoval)
            XCTAssertNil(model.pendingAction)
            model.resumeConnection()
            model.suspendConnection()
            if failsRemoval {
                XCTAssertNotNil(model.actionError, "Background/foreground cannot hide a failed secure-storage write")
            } else {
                await model.perform(.unpair)
                XCTAssertEqual(store.removeCalls, 1, "Repeating a completed unpair is idempotent")
            }
        }
    }

    func testHeldDatabaseStopPersistsThroughBackgroundAndSerializesUnpairWithVisibleFailures() async throws {
        for failsStop in [false, true] {
            let database = try AppDatabase.inMemory()
            var meeting = Meeting(title: "Held Stop", startedAt: Date(), state: .recorded, originDeviceId: "recovery-test")
            meeting.audioFileName = "unused.caf"
            meeting.audioByteCount = 1
            meeting.audioSHA256 = String(repeating: "0", count: 64)
            try await MeetingRepository(database).insert(meeting)
            let outbox = MeetingCopyOutbox(database)
            let snapshot = try await outbox.snapshot(meetingID: meeting.id)
            let store = PairingStoreProbe()
            let pin = MacPairedDevice(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, name: "Mac", pairedAt: Date())
            store.saved = [pin]
            let entry = try await outbox.enqueue(snapshot: snapshot, peerKey: pin.publicKey,
                                                 manifest: Data([1]), transcript: Data([1]), sourceIdentity: Data([1]))
            if failsStop {
                try await database.writer.write { db in
                    try db.execute(sql: """
                        CREATE TRIGGER reject_stop BEFORE UPDATE OF state ON meetingCopyOutbox
                        WHEN new.state = 'cancelled' BEGIN SELECT RAISE(ABORT, 'injected stop persistence failure'); END
                        """)
                }
            }
            let discovery = RecoveryDiscoveryProbe(endpoint: .hostPort(host: "127.0.0.1", port: 1))
            let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
            let client = IOSMacPairingClient(store: store, timeouts: timeouts)
            model.enablePairing(using: client)
            // Stop needs no audio access; this path is never created or read.
            let audio = AudioFileStore(directory: URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "unused-recovery-audio"))
            await model.enableMeetingCopies(database: database, store: audio)
            let gate = DispatchSemaphore(value: 0)
            let entered = expectation(description: "SQLite writer held")
            let holder = Task.detached {
                try await database.writer.writeWithoutTransaction { _ in
                    entered.fulfill()
                    gate.wait()
                }
            }
            defer { gate.signal(); model.suspendConnection() }
            await fulfillment(of: [entered], timeout: 2)
            let stop = Task { await model.perform(.requestCancellation(entry.id)) }
            try await pairingEventually { model.pendingAction == .requestCancellation(entry.id) }
            let duplicateStop = Task { await model.perform(.requestCancellation(entry.id)) }
            let unpair = Task { await model.perform(.unpair) }
            model.suspendConnection()
            stop.cancel()
            unpair.cancel()
            await model.perform(.cancelPairing)
            model.resumeConnection()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.removeCalls, 0, "Unpair must wait for the previously accepted durable Stop")
            XCTAssertEqual(store.identityCalls, 0, "New authentication cannot overtake persistent intent")
            XCTAssertEqual(model.pendingAction, .requestCancellation(entry.id))
            gate.signal()
            try await holder.value
            await stop.value
            await duplicateStop.value
            await unpair.value
            let persisted = try await outbox.entry(id: entry.id)
            XCTAssertEqual(persisted.state, failsStop ? "queued" : "cancelled")
            XCTAssertEqual(store.removeCalls, 1)
            XCTAssertTrue(store.saved.isEmpty)
            XCTAssertEqual(model.actionError != nil, failsStop, "Persistent failure must survive cancellation and a later successful unpair")
            XCTAssertNil(model.pendingAction)
            XCTAssertFalse(model.isConnected)
        }
    }

    func testFullScreenSubmissionCoverPreservesConnectionButSceneBackgroundRevokesIt() async throws {
        var heartbeats = 0
        let server = try PairingTCPFixture { peer in
            try await self.acceptReconnect(peer, onHeartbeat: { heartbeats += 1 }, onApplicationMessage: {})
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await server.start(), hint: true)
        let store = PairingStoreProbe()
        store.saved = [server.pin()]
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        model.enablePairing(using: client)
        var connectionLosses = 0
        let applyState = client.onUpdate
        client.onUpdate = { state in
            switch state {
            case .disconnected, .failed: connectionLosses += 1
            default: break
            }
            applyState?(state)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = RecoveryCoverState()
        let meeting = Meeting(title: "Foreground confirmation", startedAt: Date(), originDeviceId: "recovery-test")
        let controller = RecoveryCoverHostingController(rootView: RecoveryCoverHarness(model: model, meeting: meeting, state: state))
        func diagnostic(_ stage: String) {
            print("RECOVERY_COVER stage=\(stage) status=\(model.statusKey) searches=\(discovery.starts) accepted=\(server.acceptedCount) losses=\(connectionLosses) heartbeats=\(heartbeats) probe=\(client.canProbeMeetingTransfer) acceptedCapability=\(model.supportsMeetingTransfer) phase=\(state.phase) cover=\(state.coverAppeared) keyWindow=\(window.isKeyWindow) presentedController=\(controller.presentedViewController != nil) hostAppeared=\(controller.appeared)")
        }
        func gate(_ stage: String, _ condition: () -> Bool) async throws {
            diagnostic("\(stage)-begin")
            do {
                try await pairingEventually(condition)
                diagnostic("\(stage)-passed")
            } catch {
                diagnostic("\(stage)-failed")
                print("RECOVERY_COVER errorType=\(String(reflecting: type(of: error))) error=\(String(reflecting: error)) pairingTimeout=\((error as? PairingTestError) == .timeout)")
                throw error
            }
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        diagnostic("window-visible")
        addTeardownBlock { @MainActor in
            print("RECOVERY_COVER stage=teardown-dismiss")
            model.suspendConnection()
            server.stop()
            if controller.presentedViewController != nil {
                await withCheckedContinuation { continuation in
                    controller.dismiss(animated: false) { continuation.resume() }
                }
            }
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            print("RECOVERY_COVER stage=teardown-complete")
        }
        try await gate("initial-connection") { model.isConnected }
        try await gate("presenter-ready") { controller.appeared }
        state.presented = true
        try await gate("full-screen-cover") {
            state.coverAppeared && controller.presentedViewController?.view.window != nil
                && controller.presentedViewController?.isBeingPresented == false
        }
        let presented = try XCTUnwrap(controller.presentedViewController)
        XCTAssertTrue(model.isConnected, "A full-screen presentation is not app suspension")
        XCTAssertTrue(client.canProbeMeetingTransfer)
        XCTAssertFalse(client.supportsMeetingTransfer)
        XCTAssertFalse(model.supportsMeetingTransfer)
        XCTAssertNil(model.submissionBlockReason(meetingID: meeting.id))
        XCTAssertEqual(server.acceptedCount, 1)
        XCTAssertEqual(discovery.starts, 1)
        state.phase = .background
        try await gate("scene-background") { !model.isConnected }
        XCTAssertFalse(client.canProbeMeetingTransfer)
        XCTAssertFalse(client.supportsMeetingTransfer)
        XCTAssertFalse(model.supportsMeetingTransfer)
        XCTAssertNil(client.transferSessionID)
        state.phase = .active
        try await gate("scene-active-reconnect") { model.isConnected && server.acceptedCount == 2 }
        XCTAssertEqual(discovery.starts, 2)
        XCTAssertTrue(client.canProbeMeetingTransfer)
        XCTAssertFalse(client.supportsMeetingTransfer, "Recovered probe eligibility is not capability acceptance")
        XCTAssertFalse(model.supportsMeetingTransfer)
        XCTAssertNil(client.transferSessionID)
        XCTAssertNil(model.submissionBlockReason(meetingID: meeting.id))
        XCTAssertEqual(store.saveCalls, 0)
        XCTAssertTrue(model.jobs.isEmpty)

        let lossesBeforeDismissal = connectionLosses
        state.presented = false
        try await gate("cover-dismissed") {
            controller.presentedViewController == nil && presented.presentingViewController == nil
                && !presented.isBeingDismissed && presented.view.window == nil
        }
        let heartbeatsAfterDismissal = heartbeats
        try await gate("post-dismissal-heartbeat") { heartbeats > heartbeatsAfterDismissal }
        XCTAssertTrue(model.isConnected)
        XCTAssertTrue(client.canProbeMeetingTransfer)
        XCTAssertFalse(model.supportsMeetingTransfer)
        XCTAssertEqual(connectionLosses, lossesBeforeDismissal, "Dismissal must not disconnect the authenticated transport")
        XCTAssertEqual(server.acceptedCount, 2)
        XCTAssertEqual(discovery.starts, 2)
    }

    func testBackgroundCancelsOutstandingActionAndRejectsNewActions() async throws {
        var started = false
        var cancelled = false
        let model = MacConnectionModel(onAction: { _ in
            started = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
        })
        let action = Task { await model.perform(.retryTask("saved-copy")) }
        try await pairingEventually { started }
        model.suspendConnection()
        await action.value
        XCTAssertTrue(cancelled)
        XCTAssertNil(model.pendingAction)
        XCTAssertNil(model.actionError, "Cancelled-generation errors must not replace foreground UI")
        started = false
        await model.perform(.retryTask("saved-copy"))
        XCTAssertFalse(started)
    }

    func testSuspendCancelsOutstandingTransferReplyWithoutReplayingOnFreshSession() async throws {
        let identity = Curve25519.Signing.PrivateKey()
        var requested = false
        var unexpected = 0
        var heartbeats = 0
        let first = try PairingTCPFixture(identity: identity) { peer in
            _ = try await peer.handshake(reconnect: true)
            try await peer.expect("resume")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            while true {
                let inner = try await peer.receive()
                if inner.type == "ping" { try await peer.send(.init(type: "pong")); continue }
                _ = try MeetingCopyWire.message(inner)
                requested = true
                try await peer.waitForClose()
                return
            }
        }
        let second = try PairingTCPFixture(identity: identity) { peer in
            try await self.acceptReconnect(
                peer, onHeartbeat: { heartbeats += 1 }, onApplicationMessage: { unexpected += 1 }
            )
        }
        let discovery = RecoveryDiscoveryProbe(endpoint: try await first.start(), hint: true)
        let store = PairingStoreProbe()
        store.saved = [first.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: timeouts)
        let model = MacConnectionModel(discovery: discovery, recoveryTiming: timing)
        model.enablePairing(using: client)
        defer { model.suspendConnection(); first.stop(); second.stop() }
        model.resumeConnection()
        try await pairingEventually { model.isConnected }
        let request = Task { try await client.negotiateMeetingCopy() }
        try await pairingEventually { requested }
        model.suspendConnection()
        switch await request.result {
        case .success: XCTFail("Background must cancel a pending reply")
        case .failure: break
        }
        discovery.endpointToPublish = try await second.start()
        model.resumeConnection()
        try await pairingEventually { second.acceptedCount == 1 && model.isConnected }
        try await Task.sleep(for: .milliseconds(120))
        print("RECOVERY_CALLBACK suspended-reply heartbeats=\(heartbeats) applicationMessages=\(unexpected)")
        XCTAssertGreaterThan(heartbeats, 0)
        XCTAssertEqual(unexpected, 0)
        XCTAssertFalse(model.supportsMeetingTransfer)
    }

    func testMissingPongExpiresDespiteContinuousAuthenticatedTransferReplies() async throws {
        var pingSeen = false
        var repliesAfterPing = 0
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake(reconnect: true)
            try await peer.expect("resume")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            while true {
                let inner: MacPairingMessage
                do { inner = try await peer.receive() } catch { return }
                if inner.type == "ping" { pingSeen = true; continue }
                let request = try MeetingCopyWire.message(inner)
                var response = MeetingCopyWire.Message(.accepted, requestID: request.requestID)
                response.capability = MeetingCopyWire.capability
                try await peer.send(MeetingCopyWire.inner(response))
                if pingSeen { repliesAfterPing += 1 }
            }
        }
        let store = PairingStoreProbe()
        store.saved = [server.pin()]
        let client = IOSMacPairingClient(store: store, timeouts: .init(initial: 1, approval: 1, idle: 3, heartbeat: 0.05, pong: 0.15))
        defer { client.disconnect(); server.stop() }
        client.connect(to: try await server.start(), allowMeetingCopyProbe: true)
        try await pairingEventually { client.isConnected }
        let started = ContinuousClock.now
        let traffic = Task {
            while !Task.isCancelled {
                var request = MeetingCopyWire.Message(.capabilities)
                request.capability = MeetingCopyWire.capability
                _ = try await client.exchange(request)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { traffic.cancel() }
        try await pairingEventually { client.isFailed }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "The independent pong deadline, not idle, must expire")
        XCTAssertTrue(pingSeen)
        XCTAssertGreaterThan(repliesAfterPing, 2)
        XCTAssertFalse(client.supportsMeetingTransfer)
        XCTAssertEqual(store.saved.count, 1)
        _ = await traffic.result
    }

    private func acceptReconnect(
        _ peer: PairingTestPeer, onHeartbeat: () -> Void, onApplicationMessage: () -> Void
    ) async throws {
        _ = try await peer.handshake(reconnect: true)
        try await peer.expect("resume")
        try await peer.send(.init(type: "ready"))
        try await peer.expect("ready")
        while true {
            let message: MacPairingMessage
            do { message = try await peer.receive() } catch { return }
            if message.type == "ping" {
                try await peer.send(.init(type: "pong"))
                onHeartbeat()
            }
            else { onApplicationMessage(); XCTFail("Recovery sent unexpected application message \(message.type)") }
        }
    }
}

@MainActor
private final class RecoveryCoverState: ObservableObject {
    @Published var presented = false
    @Published var phase: ScenePhase = .active
    var coverAppeared = false
}

@MainActor
private final class RecoveryCoverHostingController: UIHostingController<RecoveryCoverHarness> {
    private(set) var appeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        print("RECOVERY_COVER host=viewDidAppear")
    }
}

private struct RecoveryCoverHarness: View {
    let model: MacConnectionModel
    let meeting: Meeting
    @ObservedObject var state: RecoveryCoverState

    var body: some View {
        Text("Connection owner")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(MacConnectionSceneLifecycle(model: model))
            .fullScreenCover(isPresented: $state.presented) {
                MacSubmissionView(meeting: meeting, model: model, onEnqueue: {})
                    .onAppear { state.coverAppeared = true }
            }
            .environment(\.scenePhase, state.phase)
    }
}

@MainActor
private final class RecoveryDiscoveryProbe: MacDiscovering {
    var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)?
    var device: MacConnectionModel.Device
    var endpointToPublish: NWEndpoint
    var publishesDevices = true
    var denied = false
    private(set) var starts = 0
    private var active = false

    init(endpoint: NWEndpoint, hint: Bool = false) {
        endpointToPublish = endpoint
        device = .init(id: "candidate", name: "Test Mac", meetingCopyProbeHint: hint)
    }

    func endpoint(for deviceID: String) -> NWEndpoint? {
        active && deviceID == device.id ? endpointToPublish : nil
    }

    func start() {
        active = true
        starts += 1
        if denied { onUpdate?(.permissionDenied) }
        else { publish() }
    }

    func publish() { if active { onUpdate?(.devices(publishesDevices ? [device] : [])) } }
    func stop() { active = false }
}
