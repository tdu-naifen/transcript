import Accelerate
import Foundation

/// Conversion between `[Float]` and raw little-endian Float32 `Data`,
/// plus brute-force cosine similarity (PLAN §4.4 — no vector index).
public enum FloatVector {
    public static func normalized(_ floats: [Float]) -> [Float]? {
        guard !floats.isEmpty, floats.allSatisfy(\.isFinite) else { return nil }
        var norm: Float = 0
        vDSP_svesq(floats, 1, &norm, vDSP_Length(floats.count))
        let magnitude = norm.squareRoot()
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        var result = Array(repeating: Float.zero, count: floats.count)
        var divisor = magnitude
        vDSP_vsdiv(floats, 1, &divisor, &result, 1, vDSP_Length(floats.count))
        return result
    }

    public static func dot(
        _ lhs: UnsafeBufferPointer<Float>,
        _ rhs: UnsafeBufferPointer<Float>
    ) -> Float {
        guard lhs.count == rhs.count else { return .nan }
        var result: Float = 0
        vDSP_dotpr(lhs.baseAddress!, 1, rhs.baseAddress!, 1, &result, vDSP_Length(lhs.count))
        return result
    }

    public static func isValidStorage(_ data: Data, dimension: Int) -> Bool {
        dimension > 0 && data.count == dimension * MemoryLayout<Float>.size
    }
    public static func data(from floats: [Float]) -> Data {
        var out = Data(capacity: floats.count * 4)
        for value in floats {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        }
        return out
    }

    public static func floats(from data: Data) -> [Float] {
        let count = data.count / 4
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let start = data.startIndex + i * 4
            var bits: UInt32 = 0
            for byte in 0..<4 {
                bits |= UInt32(data[start + byte]) << (8 * UInt32(byte))
            }
            out.append(Float(bitPattern: bits))
        }
        return out
    }

    /// Returns 0 for mismatched or zero-magnitude vectors.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = (normA * normB).squareRoot()
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }
}
