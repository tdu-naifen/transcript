import CryptoKit
import Foundation

/// Application protocol inside the unchanged pairing-v1 authenticated cipher.
enum MeetingCopyWire {
    static let capability = "immutableMeetingCopy.v2"
    static let innerType = "meetingCopy.v2"
    // Pairing-v1 JSON escapes "/" again inside the wrapped JSON string.
    // 1024 bytes of 0xff exceeded the actual encrypted 4096-byte frame.
    static let chunkLimit = 768
    static let transcriptLimit = 16 * 1024 * 1024
    static let audioLimit: UInt64 = 8 * 1024 * 1024 * 1024
    static let manifestLimit = 1600

    enum Failure: String, Error, Codable, Sendable {
        case incompatible, invalid, conflict, storage, staleSnapshot, cancelled, busy
    }

    struct Asset: Codable, Equatable, Sendable {
        let length: UInt64
        let sha256: String
    }

    struct Manifest: Codable, Equatable, Sendable {
        let meetingID: String
        let title: String
        let startedAtMs: Int64
        let createdAtMs: Int64
        let updatedAtMs: Int64
        let durationMs: Int64
        let locale: String?
        let audio: Asset
        let transcript: Asset
        let transcriptRevision: String
        let parentRevision: String?
        let source: String

        func validate() throws {
            guard validID(meetingID), validID(transcriptRevision),
                  parentRevision == nil || (validID(parentRevision!) && parentRevision != transcriptRevision),
                  !title.isEmpty, title.utf8.count <= 512, validLocale(locale),
                  (0...253_402_300_799_999).contains(startedAtMs),
                  (0...253_402_300_799_999).contains(createdAtMs),
                  (createdAtMs...253_402_300_799_999).contains(updatedAtMs),
                  (0...604_800_000).contains(durationMs),
                  audio.length > 0, audio.length <= audioLimit, validHash(audio.sha256),
                  transcript.length > 0, transcript.length <= transcriptLimit, validHash(transcript.sha256),
                  source == "publishedLocalTranscript" else { throw Failure.invalid }
        }
    }

    struct Utterance: Codable, Equatable, Sendable {
        let id: String
        let startMs: Int64
        let endMs: Int64
        let text: String
        let locale: String?
        let revision: Int
        let source: String
    }

    struct Transcript: Codable, Equatable, Sendable {
        let revision: String
        let parentRevision: String?
        let locale: String?
        let utterances: [Utterance]

        func validate(manifest: Manifest) throws {
            guard revision == manifest.transcriptRevision, parentRevision == manifest.parentRevision,
                  locale == manifest.locale, utterances.count <= 100_000,
                  Set(utterances.map(\.id)).count == utterances.count else { throw Failure.invalid }
            var previous: Int64 = 0
            for item in utterances {
                guard validID(item.id), item.startMs >= previous, item.endMs >= item.startMs,
                      item.endMs <= manifest.durationMs, item.text.utf8.count <= 65_536,
                      validLocale(item.locale), (1...Int(Int32.max)).contains(item.revision),
                      ["appleSpeech", "nemotron"].contains(item.source) else { throw Failure.invalid }
                previous = item.startMs
            }
        }
    }

    struct Operation: Codable, Equatable, Sendable {
        let id: String
        let meetingID: String
        let manifestSHA256: String
    }

    enum Kind: String, Codable, Sendable {
        case capabilities, accepted, offer, status, chunk, ack, finalize, committed, failed
    }

    enum AssetName: String, Codable, Sendable { case audio, transcript }

    struct Prefix: Codable, Equatable, Sendable {
        let asset: Asset
        let offset: UInt64
        let prefixSHA256: String
    }

    /// Flat, explicitly keyed JSON. No compiler-synthesized associated-value enum wire.
    struct Message: Codable, Equatable, Sendable {
        var version = 2
        let type: Kind
        let requestID: String
        var capability: String?
        var operation: Operation?
        var manifest: Data?
        var audio: Prefix?
        var transcript: Prefix?
        var prefix: Prefix?
        var asset: AssetName?
        var offset: UInt64?
        var bytes: Data?
        var sha256: String?
        var receiptID: String?
        var failure: Failure?

        init(_ type: Kind, requestID: String = UUID().uuidString.lowercased()) {
            self.type = type
            self.requestID = requestID
        }

        func validate() throws {
            guard version == 2, validID(requestID) else { throw Failure.invalid }
            let object = try JSONSerialization.jsonObject(with: MeetingCopyWire.encode(self)) as! [String: Any]
            let actual = Set(object.keys)
            var expected: Set<String> = ["version", "type", "requestID"]
            switch type {
            case .capabilities, .accepted:
                expected.insert("capability")
                guard capability == MeetingCopyWire.capability else { throw Failure.incompatible }
            case .offer:
                expected.formUnion(["operation", "manifest"])
                guard let manifest else { throw Failure.invalid }
                let decoded = try decodeManifest(manifest)
                guard decoded.meetingID == operation?.meetingID,
                      hash(manifest) == operation?.manifestSHA256 else { throw Failure.invalid }
            case .status:
                expected.formUnion(["operation", "audio", "transcript"])
                guard let audio, let transcript else { throw Failure.invalid }
                try validatePrefix(audio, limit: audioLimit)
                try validatePrefix(transcript, limit: UInt64(transcriptLimit))
            case .chunk:
                expected.formUnion(["operation", "asset", "offset", "bytes", "sha256"])
                guard asset != nil, let offset, offset <= audioLimit, let bytes,
                      !bytes.isEmpty, bytes.count <= chunkLimit,
                      UInt64(bytes.count) <= audioLimit - offset, sha256 == hash(bytes) else { throw Failure.invalid }
            case .ack:
                expected.formUnion(["operation", "asset", "prefix"])
                guard asset != nil, let prefix else { throw Failure.invalid }
                try validatePrefix(prefix, limit: asset == .audio ? audioLimit : UInt64(transcriptLimit))
            case .finalize:
                expected.insert("operation")
            case .committed:
                expected.formUnion(["operation", "receiptID"])
                guard let receiptID, validID(receiptID) else { throw Failure.invalid }
            case .failed:
                expected.formUnion(["operation", "failure"])
                guard failure != nil else { throw Failure.invalid }
            }
            guard Set(actual) == expected else { throw Failure.invalid }
            if expected.contains("operation") {
                guard let operation, validID(operation.id), validID(operation.meetingID),
                      validHash(operation.manifestSHA256) else { throw Failure.invalid }
            }
        }
    }

    static func validatePrefix(_ prefix: Prefix, limit: UInt64) throws {
        guard prefix.asset.length > 0, prefix.asset.length <= limit,
              prefix.offset <= prefix.asset.length,
              validHash(prefix.asset.sha256), validHash(prefix.prefixSHA256) else { throw Failure.invalid }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Codable>(_ type: T.Type, from bytes: Data, limit: Int) throws -> T {
        guard !bytes.isEmpty, bytes.count <= limit else { throw Failure.invalid }
        let value = try JSONDecoder().decode(type, from: bytes)
        // Reject duplicate/unknown keys, alternate base64, null optionals and noncanonical JSON.
        guard try encode(value) == bytes else { throw Failure.invalid }
        return value
    }

    static func decodeManifest(_ bytes: Data) throws -> Manifest {
        let manifest = try decode(Manifest.self, from: bytes, limit: manifestLimit)
        try manifest.validate()
        return manifest
    }

    static func inner(_ message: Message) throws -> MacPairingMessage {
        try message.validate()
        let data = try encode(message)
        guard data.count <= 2800, let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        return MacPairingMessage(type: innerType, value: text)
    }

    static func message(_ inner: MacPairingMessage) throws -> Message {
        guard inner.type == innerType, let value = inner.value else { throw Failure.invalid }
        let message = try decode(Message.self, from: Data(value.utf8), limit: 2800)
        try message.validate()
        return message
    }

    static func hash(_ bytes: Data) -> String { Data(SHA256.hash(data: bytes)).base64EncodedString() }
    static func validHash(_ value: String) -> Bool {
        guard value.utf8.count == 44, let bytes = Data(base64Encoded: value) else { return false }
        return bytes.count == 32 && bytes.base64EncodedString() == value
    }
    static func validID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
            && value != "00000000-0000-0000-0000-000000000000"
    }
    static func validLocale(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy { (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
    }
}
