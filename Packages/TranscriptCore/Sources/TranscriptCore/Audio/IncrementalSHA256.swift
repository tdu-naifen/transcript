import CryptoKit
import Foundation

/// SHA-256 fed as the bytes are produced, so the file is never re-read to hash it.
/// This is the digest the Mac re-computes to gate local audio deletion (PLAN §3.4).
public struct IncrementalSHA256 {
    private var hasher = SHA256()
    public private(set) var byteCount: Int = 0

    public init() {}

    public mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        hasher.update(data: data)
        byteCount += data.count
    }

    public mutating func finalize() -> String {
        Self.hex(hasher.finalize())
    }

    public static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// One streaming pass over a file that already exists, for crash recovery only.
    /// The live recording path hashes while writing instead.
    public static func hashFile(at url: URL, chunkBytes: Int = 1 << 20) throws -> (sha256: String, byteCount: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = IncrementalSHA256()
        while let data = try handle.read(upToCount: chunkBytes), !data.isEmpty {
            hasher.update(data)
        }
        let count = hasher.byteCount
        return (hasher.finalize(), count)
    }
}
