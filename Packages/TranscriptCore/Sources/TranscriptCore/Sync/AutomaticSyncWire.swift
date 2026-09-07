import Foundation

/// Versioned independently from immutable meeting-copy v2 and the pairing protocol.
public enum AutomaticSyncWire {
    public static let capability = "automaticSync.v1"
    public static let messageType = "automaticSync.v1"
    public static let maximumMessageBytes = 2_800
    public static let maximumOperationBytes = 4_194_304
    public static let emittedFragmentBytes = 512

    public enum Entity: String, Codable, Sendable, CaseIterable {
        case meeting, speaker, utterance, association, resource
    }

    public enum Consent: String, Codable, Sendable {
        case denied, allowed, paused, revoked
    }

    public struct Stamp: Codable, Hashable, Comparable, Sendable {
        public var counter: Int64
        public var deviceID: String
        public var operationID: String

        public init(counter: Int64, deviceID: String, operationID: String = UUID().uuidString.lowercased()) {
            self.counter = counter
            self.deviceID = deviceID
            self.operationID = operationID
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
            if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
            return lhs.operationID < rhs.operationID
        }
    }

    /// Scalar values use SQLite's stable text representation; nil is an explicit
    /// cleared value, not an omitted mutation. Field names are schema-whitelisted.
    public struct Operation: Codable, Hashable, Sendable {
        public var stamp: Stamp
        public var entity: Entity
        public var entityID: String
        public var field: String
        public var value: String?
        public var isDelete: Bool
        public var biometric: Bool

        public var id: String { stamp.operationID }

        public init(stamp: Stamp, entity: Entity, entityID: String, field: String,
                    value: String?, isDelete: Bool = false, biometric: Bool? = nil) {
            self.stamp = stamp
            self.entity = entity
            self.entityID = entityID
            self.field = field
            self.value = value
            self.isDelete = isDelete
            self.biometric = biometric ?? (entity == .speaker || entity == .association
                || (entity == .utterance && field == "speakerId"))
        }
    }

    public struct Resource: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case audio, transcript, analysis, voiceprint
        }
        public var kind: Kind
        public var meetingID: String?
        public var speakerID: String?
        public var sha256: String
        public var byteCount: Int64
        public var modelFingerprint: String?
        public var preprocessing: String?
        public var dimensions: Int?
        public var sampleCount: Int?
        public var inputRevision: String?
        public var sealed: Bool

        public init(kind: Kind, meetingID: String? = nil, speakerID: String? = nil,
                    sha256: String, byteCount: Int64, modelFingerprint: String? = nil,
                    preprocessing: String? = nil, dimensions: Int? = nil,
                    inputRevision: String? = nil, sealed: Bool = true, sampleCount: Int? = nil) {
            self.kind = kind
            self.meetingID = meetingID
            self.speakerID = speakerID
            self.sha256 = sha256
            self.byteCount = byteCount
            self.modelFingerprint = modelFingerprint
            self.preprocessing = preprocessing
            self.dimensions = dimensions
            self.sampleCount = sampleCount
            self.inputRevision = inputRevision
            self.sealed = sealed
        }
    }

    /// A single bounded fragment permits large text registers without exceeding
    /// pairing's unchanged encrypted frame ceiling. Offset is UTF-8 byte offset.
    public struct Fragment: Codable, Hashable, Sendable {
        public var operationID: String
        public var offset: Int
        public var total: Int
        public var bytes: Data

        public init(operationID: String, offset: Int, total: Int, bytes: Data) {
            self.operationID = operationID
            self.offset = offset
            self.total = total
            self.bytes = bytes
        }
    }

    public struct Message: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case hello, accepted, fragment, ack }
        public var version: Int = 1
        public var kind: Kind
        public var requestID: String
        public var capability: String?
        public var fragment: Fragment?
        public var operationID: String?
        public var voiceprintsAllowed: Bool

        public init(kind: Kind, requestID: String = UUID().uuidString.lowercased(),
                    capability: String? = nil, fragment: Fragment? = nil, operationID: String? = nil,
                    voiceprintsAllowed: Bool = false) {
            self.kind = kind
            self.requestID = requestID
            self.capability = capability
            self.fragment = fragment
            self.operationID = operationID
            self.voiceprintsAllowed = voiceprintsAllowed
        }

        private enum CodingKeys: String, CodingKey {
            case version, kind, requestID, capability, fragment, operationID, voiceprintsAllowed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            kind = try c.decode(Kind.self, forKey: .kind)
            requestID = try c.decode(String.self, forKey: .requestID)
            capability = try c.decodeIfPresent(String.self, forKey: .capability)
            fragment = try c.decodeIfPresent(Fragment.self, forKey: .fragment)
            operationID = try c.decodeIfPresent(String.self, forKey: .operationID)
            voiceprintsAllowed = kind == .hello || kind == .accepted
                ? try c.decode(Bool.self, forKey: .voiceprintsAllowed) : false
            if kind != .hello && kind != .accepted && c.contains(.voiceprintsAllowed) {
                throw Failure.invalid
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version)
            try c.encode(kind, forKey: .kind)
            try c.encode(requestID, forKey: .requestID)
            try c.encodeIfPresent(capability, forKey: .capability)
            try c.encodeIfPresent(fragment, forKey: .fragment)
            try c.encodeIfPresent(operationID, forKey: .operationID)
            if kind == .hello || kind == .accepted {
                try c.encode(voiceprintsAllowed, forKey: .voiceprintsAllowed)
            } else if voiceprintsAllowed {
                throw Failure.invalid
            }
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalid, unsupported, disabled, consentRequired, equivocation, clockExhausted
        case immutableResource, staleRevision, hashMismatch, resourceUnavailable
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    // ASCII makes Swift stamp ordering identical to SQLite BINARY ordering.
    static func validStampID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    public static func decode(_ data: Data) throws -> Message {
        guard data.count <= maximumMessageBytes else { throw Failure.invalid }
        let result = try JSONDecoder().decode(Message.self, from: data)
        guard result.version == 1 else { throw Failure.unsupported }
        guard !result.requestID.isEmpty, result.requestID.utf8.count <= 128,
              try encode(result) == data else { throw Failure.invalid }
        switch result.kind {
        case .hello, .accepted:
            guard result.capability == capability, result.fragment == nil,
                  result.operationID == nil else { throw Failure.invalid }
        case .fragment:
            guard let fragment = result.fragment, result.capability == nil,
                  result.operationID == nil, validStampID(fragment.operationID),
                  fragment.total > 0, fragment.total <= maximumOperationBytes,
                  fragment.offset >= 0, fragment.offset <= fragment.total,
                  !fragment.bytes.isEmpty, fragment.bytes.count <= 768,
                  fragment.bytes.count <= fragment.total - fragment.offset else { throw Failure.invalid }
        case .ack:
            guard let id = result.operationID, validStampID(id),
                  result.capability == nil, result.fragment == nil else { throw Failure.invalid }
        }
        return result
    }

    public static func fragments(for operation: Operation) throws -> [Fragment] {
        let bytes = try encode(operation)
        guard bytes.count <= maximumOperationBytes else { throw Failure.invalid }
        return stride(from: 0, to: bytes.count, by: emittedFragmentBytes).map { offset in
            Fragment(operationID: operation.id, offset: offset, total: bytes.count,
                     bytes: bytes.subdata(in: offset..<min(offset + emittedFragmentBytes, bytes.count)))
        }
    }
}
