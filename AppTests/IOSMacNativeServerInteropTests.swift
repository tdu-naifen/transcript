import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import Transcript

/// Opt-in only: the driver must supply an authenticated, isolated native Mac QA endpoint.
@MainActor
final class IOSMacNativeServerInteropTests: XCTestCase {
    func testProductionNativeServerAndSimulatorClientInteroperate() async throws {
        let configuration = try NativeInteropConfiguration.load()
        let control = NativeInteropControl(configuration: configuration)
        let service = "com.transcript.qa.pairing.\(configuration.runID).ios"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        let initialStatus = SecItemCopyMatching(query as CFDictionary, nil)
        guard initialStatus == errSecItemNotFound else {
            throw NativeInteropError.namespaceNotFresh(initialStatus)
        }
        let store = MacPairingKeychainStore(service: service)
        var client = IOSMacPairingClient(store: store, name: "Isolated iOS Simulator QA")
        defer {
            client.disconnect()
            let status = SecItemDelete(query as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "Exact iOS namespace cleanup failed: \(status)")
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        }

        let clientIdentity = try store.identity().publicKey.rawRepresentation
        let initial = try await control.request("snapshot")
        XCTAssertTrue(initial.peers.isEmpty)
        XCTAssertEqual(initial.state, "idle")
        let serverIdentity = try XCTUnwrap(Data(base64Encoded: initial.identity))
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: configuration.pairingPort))
        )

        client.connect(to: endpoint)
        let confirmation = try await matchingConfirmation(client: client, control: control)
        XCTAssertTrue(try store.peers().isEmpty)
        XCTAssertTrue(confirmation.peers.isEmpty)
        XCTAssertFalse(confirmation.locallyApproved)
        client.approve()
        _ = try await control.request("approve", confirmation: confirmation)
        try await waitUntil { if case .connected = client.state { return true }; return false }
        let connected = try await control.waitForState("connected")
        XCTAssertEqual(connected.connectedPeer, clientIdentity.base64EncodedString())
        XCTAssertEqual(connected.peers, [clientIdentity.base64EncodedString()])
        XCTAssertEqual(try store.peers().map(\.publicKey), [serverIdentity])

        client.disconnect()
        _ = try await control.waitForState("idle")
        let recreatedStore = MacPairingKeychainStore(service: service)
        XCTAssertEqual(try recreatedStore.identity().publicKey.rawRepresentation, clientIdentity)
        XCTAssertEqual(try recreatedStore.peers().map(\.publicKey), [serverIdentity])
        client = IOSMacPairingClient(store: recreatedStore, name: "Recreated iOS QA Client")
        try client.restoreTrust()
        XCTAssertEqual(client.pairedPeer?.publicKey, serverIdentity)
        var unexpectedlyOfferedPairing = false
        client.onUpdate = { state in
            if case .awaitingApproval = state { unexpectedlyOfferedPairing = true }
        }
        client.connect(to: endpoint)
        try await waitUntil { if case .connected = client.state { return true }; return false }
        let reconnected = try await control.waitForState("connected")
        XCTAssertFalse(unexpectedlyOfferedPairing)
        XCTAssertEqual(reconnected.identity, initial.identity)
        XCTAssertEqual(reconnected.peers, connected.peers)

        try client.unpair()
        _ = try await control.waitForState("idle")
        XCTAssertTrue(try recreatedStore.peers().isEmpty)
        XCTAssertEqual(try recreatedStore.identity().publicKey.rawRepresentation, clientIdentity)
        let reset = try await control.request("reset")
        XCTAssertEqual(reset.identity, initial.identity)
        XCTAssertTrue(reset.peers.isEmpty)

        client.connect(to: endpoint)
        let rejection = try await matchingConfirmation(client: client, control: control)
        _ = try await control.request("reject", confirmation: rejection)
        try await waitUntil { if case .failed = client.state { return true }; return false }
        XCTAssertTrue(try recreatedStore.peers().isEmpty)
        let rejected = try await control.request("snapshot")
        XCTAssertTrue(rejected.peers.isEmpty)

        _ = try await control.request("reset")
        client.connect(to: endpoint)
        let pending = try await matchingConfirmation(client: client, control: control)
        client.approve()
        // The server remains locally unapproved while its sole reader observes the approval/EOF.
        try await Task.sleep(for: .milliseconds(100))
        let stillPending = try await control.request("snapshot")
        XCTAssertEqual(stillPending.state, "awaitingConfirmation")
        XCTAssertFalse(stillPending.locallyApproved)
        XCTAssertTrue(stillPending.peers.isEmpty)
        client.disconnect()
        _ = try await control.waitForState("failed")
        let stale = try await control.request("approve", confirmation: pending)
        XCTAssertEqual(stale.state, "failed")
        XCTAssertTrue(stale.peers.isEmpty, "A stale production-server confirm must not save trust")
        XCTAssertTrue(try recreatedStore.peers().isEmpty)
        XCTAssertEqual(try recreatedStore.identity().publicKey.rawRepresentation, clientIdentity)
        XCTAssertEqual(stale.identity, initial.identity)
        XCTAssertEqual(stale.acceptedConnections, 4)
    }

    private func matchingConfirmation(
        client: IOSMacPairingClient, control: NativeInteropControl
    ) async throws -> NativeInteropSnapshot {
        try await waitUntil { if case .awaitingApproval = client.state { return true }; return false }
        let server = try await control.waitForState("awaitingConfirmation")
        guard case .awaitingApproval(let peer, let code, false) = client.state,
              code == server.code, peer.publicKey.base64EncodedString() == server.identity,
              code.count == 6, server.confirmationID != nil else {
            XCTFail("Both real production endpoints must expose the same verified SAS before either approval")
            throw NativeInteropError.codeMismatch
        }
        return server
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NativeInteropError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum NativeInteropError: Error {
    case configuration, codeMismatch, timeout, control(String), namespaceNotFresh(OSStatus)
}

private struct NativeInteropConfiguration: Decodable {
    let runID: String
    let token: String
    let pairingPort: UInt16
    let controlPort: UInt16
    let service: String

    static func load() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["TRANSCRIPT_NATIVE_INTEROP_CONFIG"] else {
            if environment["TRANSCRIPT_NATIVE_INTEROP_REQUIRED"] == "1" {
                throw NativeInteropError.configuration
            }
            throw XCTSkip("Optional native-Mac interoperability requires the isolated external QA driver.")
        }
        let configuration = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        guard UUID(uuidString: configuration.runID)?.uuidString.lowercased() == configuration.runID,
              configuration.service == "com.transcript.qa.pairing.\(configuration.runID)",
              configuration.token.count == 64,
              configuration.token.allSatisfy({ $0.isHexDigit }),
              configuration.pairingPort > 0, configuration.controlPort > 0,
              configuration.pairingPort != configuration.controlPort else {
            throw NativeInteropError.configuration
        }
        return configuration
    }
}

private struct NativeInteropSnapshot: Codable {
    let state: String
    let code: String?
    let confirmationID: String?
    let identity: String
    let peers: [String]
    let connectedPeer: String?
    let locallyApproved: Bool
    let acceptedConnections: Int
    let error: String?
}

@MainActor
private final class NativeInteropControl {
    private struct Request: Encodable {
        let runID: String
        let token: String
        let action: String
        let code: String?
        let confirmationID: String?
    }
    private let configuration: NativeInteropConfiguration
    init(configuration: NativeInteropConfiguration) { self.configuration = configuration }

    func request(_ action: String, confirmation: NativeInteropSnapshot? = nil) async throws -> NativeInteropSnapshot {
        let transport = MacPairingTransport(NWConnection(
            host: "127.0.0.1",
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: configuration.controlPort)), using: .tcp
        ))
        transport.start()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)); transport.cancel() }
            catch is CancellationError { return }
            catch { transport.cancel() }
        }
        defer { timeout.cancel(); transport.cancel() }
        let request = Request(
            runID: configuration.runID, token: configuration.token, action: action,
            code: confirmation?.code, confirmationID: confirmation?.confirmationID
        )
        try await transport.send(.init(type: "qa", payload: JSONEncoder().encode(request).base64EncodedString()))
        let frame = try await transport.receive()
        let response = try JSONDecoder().decode(NativeInteropSnapshot.self, from: frame.bytes(expectedType: "qa"))
        if let error = response.error { throw NativeInteropError.control(error) }
        return response
    }

    func waitForState(_ state: String) async throws -> NativeInteropSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            let snapshot = try await request("snapshot")
            if snapshot.state == state { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeInteropError.timeout
    }
}
