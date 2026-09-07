import Foundation

/// Optional immutable-byte companion to automaticSync.v1. Negotiate this exact
/// capability separately; a metadata-only peer must never receive these messages.
public enum AutomaticSyncResourceWire {
    public static let capability = "automaticSyncResources.v1"
    public static let messageType = "automaticSyncResources.v1"

    public struct Chunk: Codable, Hashable, Sendable {
        public var resourceID: String
        public var offset: Int64
        public var total: Int64
        public var bytes: Data

        public init(resourceID: String, offset: Int64, total: Int64, bytes: Data) {
            self.resourceID = resourceID
            self.offset = offset
            self.total = total
            self.bytes = bytes
        }
    }

    public struct Message: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case hello, accepted, request, chunk, ack, unavailable
        }
        public var version = 1
        public var kind: Kind
        public var requestID: String
        public var resourceID: String?
        public var offset: Int64?
        public var chunk: Chunk?

        public init(kind: Kind, requestID: String = UUID().uuidString.lowercased(),
                    resourceID: String? = nil, offset: Int64? = nil, chunk: Chunk? = nil) {
            self.kind = kind
            self.requestID = requestID
            self.resourceID = resourceID
            self.offset = offset
            self.chunk = chunk
        }
    }

    public static func decode(_ bytes: Data) throws -> Message {
        guard bytes.count <= AutomaticSyncWire.maximumMessageBytes else { throw AutomaticSyncWire.Failure.invalid }
        let message = try JSONDecoder().decode(Message.self, from: bytes)
        guard message.version == 1, !message.requestID.isEmpty, message.requestID.utf8.count <= 128,
              try AutomaticSyncWire.encode(message) == bytes else { throw AutomaticSyncWire.Failure.invalid }
        switch message.kind {
        case .hello, .accepted:
            guard message.resourceID == nil, message.offset == nil, message.chunk == nil else { throw AutomaticSyncWire.Failure.invalid }
        case .request, .ack:
            guard validID(message.resourceID), let offset = message.offset, offset >= 0,
                  offset <= 8 * 1_024 * 1_024 * 1_024, message.chunk == nil else { throw AutomaticSyncWire.Failure.invalid }
        case .unavailable:
            guard validID(message.resourceID), message.offset == nil, message.chunk == nil else { throw AutomaticSyncWire.Failure.invalid }
        case .chunk:
            guard let chunk = message.chunk, message.resourceID == nil, message.offset == nil,
                  validID(chunk.resourceID), chunk.total > 0, chunk.total <= 8 * 1_024 * 1_024 * 1_024,
                  chunk.offset >= 0, chunk.offset <= chunk.total,
                  !chunk.bytes.isEmpty, chunk.bytes.count <= 768,
                  chunk.bytes.count <= chunk.total - chunk.offset else { throw AutomaticSyncWire.Failure.invalid }
        }
        return message
    }

    private static func validID(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
