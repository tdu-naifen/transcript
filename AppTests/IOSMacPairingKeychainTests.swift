import CryptoKit
import Foundation
import Security
import XCTest
@testable import Transcript

@MainActor
final class IOSMacPairingKeychainTests: XCTestCase {
    func testIdentityAndPeerSurviveNewStoreAndClientRestoreTrust() throws {
        let service = isolatedService()
        let peer = makePeer()
        let identityBytes: Data
        do {
            let store = MacPairingKeychainStore(service: service)
            XCTAssertTrue(try store.peers().isEmpty)
            identityBytes = try store.identity().rawRepresentation
            try store.save(peer)
            let client = IOSMacPairingClient(store: store)
            try client.restoreTrust()
            XCTAssertEqual(client.pairedPeer, peer)
        }

        XCTAssertEqual(try storedData(service: service, account: "identity"), identityBytes)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [MacPairedDevice].self,
                from: storedData(service: service, account: "peers")
            ),
            [peer]
        )
        let reopened = MacPairingKeychainStore(service: service)
        XCTAssertEqual(try reopened.identity().rawRepresentation, identityBytes)
        XCTAssertEqual(try reopened.peers(), [peer])
        let restoredClient = IOSMacPairingClient(store: reopened)
        XCTAssertNil(restoredClient.pairedPeer)
        try restoredClient.restoreTrust()
        XCTAssertEqual(restoredClient.pairedPeer, peer)
    }

    func testUnpairRemovesPersistentPinButPreservesIdentity() throws {
        let service = isolatedService()
        let peer = makePeer()
        let identityBytes: Data
        do {
            let store = MacPairingKeychainStore(service: service)
            identityBytes = try store.identity().rawRepresentation
            try store.save(peer)
        }

        do {
            let store = MacPairingKeychainStore(service: service)
            let client = IOSMacPairingClient(store: store)
            try client.restoreTrust()
            XCTAssertEqual(client.pairedPeer, peer)
            try client.unpair()
            XCTAssertNil(client.pairedPeer)
            XCTAssertEqual(client.state, .disconnected(nil))
        }

        XCTAssertEqual(try storedData(service: service, account: "identity"), identityBytes)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [MacPairedDevice].self,
                from: storedData(service: service, account: "peers")
            ),
            []
        )
        let reopened = MacPairingKeychainStore(service: service)
        XCTAssertEqual(try reopened.identity().rawRepresentation, identityBytes)
        XCTAssertTrue(try reopened.peers().isEmpty)
        let restoredClient = IOSMacPairingClient(store: reopened)
        try restoredClient.restoreTrust()
        XCTAssertNil(restoredClient.pairedPeer)
    }

    private func isolatedService() -> String {
        let service = "com.transcript.ios.pairing.v1.test.\(UUID().uuidString)"
        let attachment = XCTAttachment(string: service)
        attachment.name = "isolated-keychain-service"
        attachment.lifetime = .keepAlways
        add(attachment)
        addTeardownBlock { @MainActor in
            for account in ["identity", "peers"] {
                let query = Self.query(service: service, account: account)
                let status = SecItemDelete(query as CFDictionary)
                XCTAssertTrue(
                    status == errSecSuccess || status == errSecItemNotFound,
                    "Exact-service cleanup failed for \(account): \(status)"
                )
                XCTAssertEqual(
                    SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound
                )
                XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecItemNotFound)
            }
        }
        for account in ["identity", "peers"] {
            XCTAssertEqual(
                SecItemCopyMatching(Self.query(service: service, account: account) as CFDictionary, nil),
                errSecItemNotFound
            )
        }
        return service
    }

    private func makePeer() -> MacPairedDevice {
        MacPairedDevice(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            name: "Isolated Keychain Test Mac",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func storedData(service: String, account: String) throws -> Data {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(result as? Data)
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
