import Foundation
import Network

/// A single serial reader; the session owns deadlines and cancels blocked I/O.
@MainActor
final class MacPairingTransport {
    static let maximumFrameSize = 4096
    let connection: NWConnection
    private let queue = DispatchQueue(label: "com.transcript.mac.pairing.transport")

    init(_ connection: NWConnection) { self.connection = connection }

    func start() { connection.start(queue: queue) }
    func cancel() { connection.cancel() }

    func send(_ frame: MacPairingFrame) async throws {
        let data = try JSONEncoder().encode(frame)
        guard !data.isEmpty, data.count <= Self.maximumFrameSize else { throw MacPairingError.invalidMessage }
        var length = UInt32(data.count).bigEndian
        let packet = withUnsafeBytes(of: &length) { Data($0) } + data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> MacPairingFrame {
        let header = try await readExactly(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...Self.maximumFrameSize).contains(length) else { throw MacPairingError.invalidMessage }
        let data = try await readExactly(length)
        // Reject unknown fields and wrong JSON scalar types before Codable's permissive decoding.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["type", "payload", "mode", "counter"]) else {
            throw MacPairingError.invalidMessage
        }
        return try JSONDecoder().decode(MacPairingFrame.self, from: data)
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: MacPairingError.invalidMessage) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}
