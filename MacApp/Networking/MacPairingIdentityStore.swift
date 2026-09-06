import CryptoKit
import Foundation
import Security

struct MacPairedDevice: Codable, Equatable, Identifiable, Sendable {
    let publicKey: Data
    let name: String
    let pairedAt: Date
    var id: String { publicKey.base64EncodedString() }
    var fingerprint: String {
        MacPairingCrypto.hash(publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol MacPairingIdentityStoring: AnyObject {
    func identity() throws -> Curve25519.Signing.PrivateKey
    func peers() throws -> [MacPairedDevice]
    func save(_ peer: MacPairedDevice) throws
    func remove(publicKey: Data) throws
}

@MainActor
final class MacPairingKeychainStore: MacPairingIdentityStoring {
    private let service: String

    init(service: String = "com.transcript.mac.pairing.v1") { self.service = service }

    func identity() throws -> Curve25519.Signing.PrivateKey {
        if let data = try read("identity") {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        var item = query("identity")
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read("identity") {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: existing)
        }
        guard status == errSecSuccess else { throw MacPairingError.keychain(status) }
        return key
    }

    func peers() throws -> [MacPairedDevice] {
        guard let data = try read("peers") else { return [] }
        let peers = try JSONDecoder().decode([MacPairedDevice].self, from: data)
        guard peers.count <= 32, peers.allSatisfy({ $0.publicKey.count == 32 }) else {
            throw MacPairingError.invalidMessage
        }
        return peers
    }

    func save(_ peer: MacPairedDevice) throws {
        var peers = try peers().filter { $0.publicKey != peer.publicKey }
        guard peers.count < 32 else { throw MacPairingError.unavailable }
        peers.append(peer)
        try write(JSONEncoder().encode(peers), account: "peers")
    }

    func remove(publicKey: Data) throws {
        try write(JSONEncoder().encode(peers().filter { $0.publicKey != publicKey }), account: "peers")
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MacPairingError.keychain(status)
        }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let query = query(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MacPairingError.keychain(status) }
    }
}
