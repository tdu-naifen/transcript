import CryptoKit
import Foundation
import Security

enum MacPairingError: Error, LocalizedError {
    case invalidMessage, identityMismatch, rejected, timedOut, unavailable, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidMessage: String(localized: "The secure connection could not be verified. Try pairing again.")
        case .identityMismatch: String(localized: "This device is not trusted. Unpair and explicitly pair again.")
        case .rejected: String(localized: "Pairing was rejected. Compare the codes before trying again.")
        case .timedOut: String(localized: "Pairing timed out. Keep both devices open and try again.")
        case .unavailable: String(localized: "Enable pairing on this Mac, then try again.")
        case .keychain: String(localized: "Secure identity storage is unavailable. No new device was trusted.")
        }
    }
}

enum MacPairingCrypto {
    static let domain = Data("TranscriptPairing/v1/".utf8)

    static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MacPairingError.unavailable
        }
        return Data(bytes)
    }

    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func commitment(role: String, hello: Data) -> Data {
        hash(domain + Data("commit/\(role)".utf8) + hello)
    }

    static func transcript(client: Data, server: Data) -> Data {
        hash(domain + Data("transcript/".utf8) + client + server)
    }

    static func signatureInput(role: String, transcript: Data) -> Data {
        domain + Data("auth/\(role)".utf8) + transcript
    }

    static func integer(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct MacPairingHello {
    let reconnect: Bool
    let identity: Data
    let ephemeral: Data
    let nonce: Data
    let name: String

    func encoded() throws -> Data {
        let text = Data(name.utf8)
        guard identity.count == 32, ephemeral.count == 32, nonce.count == 32,
              !text.isEmpty, text.count <= 63,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MacPairingError.invalidMessage
        }
        return Data([reconnect ? 1 : 0]) + identity + ephemeral + nonce
            + Data([0, UInt8(text.count)]) + text
    }

    init(reconnect: Bool, identity: Data, ephemeral: Data, nonce: Data, name: String) {
        self.reconnect = reconnect
        self.identity = identity
        self.ephemeral = ephemeral
        self.nonce = nonce
        self.name = name
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 100, bytes[0] <= 1 else { throw MacPairingError.invalidMessage }
        let size = Int(bytes[97]) * 256 + Int(bytes[98])
        guard size > 0, size <= 63, bytes.count == 99 + size,
              let name = String(data: Data(bytes[99...]), encoding: .utf8) else {
            throw MacPairingError.invalidMessage
        }
        self.init(
            reconnect: bytes[0] == 1,
            identity: Data(bytes[1..<33]), ephemeral: Data(bytes[33..<65]),
            nonce: Data(bytes[65..<97]), name: name
        )
        _ = try encoded()
    }
}

struct MacPairingFrame: Codable, Sendable {
    let type: String
    var payload: String?
    var mode: String?
    var counter: UInt64?

    func bytes(expectedType: String, count: Int? = nil) throws -> Data {
        guard type == expectedType, let payload, let result = Data(base64Encoded: payload),
              count == nil || result.count == count else { throw MacPairingError.invalidMessage }
        return result
    }
}

struct MacPairingMessage: Codable, Sendable {
    let type: String
    var value: String?
}

struct MacPairingCipher {
    let transcript: Data
    let sendDirection: String
    let receiveDirection: String
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    let code: String
    private(set) var sendCounter: UInt64 = 0
    private(set) var receiveCounter: UInt64 = 0

    init(secret: SharedSecret, transcript: Data, server: Bool) {
        self.transcript = transcript
        sendDirection = server ? "s2c" : "c2s"
        receiveDirection = server ? "c2s" : "s2c"
        func key(_ purpose: String, count: Int = 32) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: transcript,
                sharedInfo: MacPairingCrypto.domain + Data(purpose.utf8), outputByteCount: count
            )
        }
        sendKey = key(sendDirection)
        receiveKey = key(receiveDirection)
        let number = key("sas", count: 8).withUnsafeBytes { bytes in
            bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        code = String(format: "%06llu", number % 1_000_000)
    }

    private func aad(_ direction: String, _ counter: UInt64) -> Data {
        MacPairingCrypto.domain + Data("sealed/\(direction)".utf8)
            + transcript + MacPairingCrypto.integer(counter)
    }

    mutating func seal(_ message: MacPairingMessage) throws -> MacPairingFrame {
        guard sendCounter < UInt64.max else { throw MacPairingError.invalidMessage }
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + MacPairingCrypto.integer(sendCounter))
        let box = try ChaChaPoly.seal(
            JSONEncoder().encode(message), using: sendKey, nonce: nonce,
            authenticating: aad(sendDirection, sendCounter)
        )
        defer { sendCounter += 1 }
        return MacPairingFrame(type: "sealed", payload: box.combined.base64EncodedString(), counter: sendCounter)
    }

    mutating func open(_ frame: MacPairingFrame) throws -> MacPairingMessage {
        guard frame.counter == receiveCounter, receiveCounter < UInt64.max, frame.mode == nil else {
            throw MacPairingError.invalidMessage
        }
        let box = try ChaChaPoly.SealedBox(combined: frame.bytes(expectedType: "sealed"))
        let expectedNonce = Data(repeating: 0, count: 4) + MacPairingCrypto.integer(receiveCounter)
        guard MacPairingCrypto.constantTimeEqual(Data(box.nonce), expectedNonce) else {
            throw MacPairingError.invalidMessage
        }
        let plaintext = try ChaChaPoly.open(
            box, using: receiveKey, authenticating: aad(receiveDirection, receiveCounter)
        )
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              Set(object.keys).isSubset(of: ["type", "value"]) else {
            throw MacPairingError.invalidMessage
        }
        let message = try JSONDecoder().decode(MacPairingMessage.self, from: plaintext)
        receiveCounter += 1
        return message
    }
}
