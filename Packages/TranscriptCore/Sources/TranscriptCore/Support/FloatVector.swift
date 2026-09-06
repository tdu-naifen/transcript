import Accelerate
import Foundation

/// Conversion between `[Float]` and raw little-endian Float32 `Data`,
/// plus brute-force cosine similarity (PLAN §4.4 — no vector index).
public enum FloatVector {
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

    public static func isValidStorage(_ data: Data, dimension: Int) -> Bool {
        dimension > 0 && data.count.isMultiple(of: MemoryLayout<Float>.size)
            && data.count / MemoryLayout<Float>.size == dimension
    }

    /// Returns a unit vector only when every component and the magnitude are finite.
    public static func normalized(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        var squaredMagnitude: Float = 0
        for value in values { squaredMagnitude += value * value }
        let magnitude = squaredMagnitude.squareRoot()
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return values.map { $0 / magnitude }
    }

    static func dot(
        _ a: UnsafeBufferPointer<Float>,
        _ b: UnsafeBufferPointer<Float>
    ) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return vDSP.dot(a, b)
    }

    /// Returns 0 for mismatched, non-finite, or zero-magnitude vectors.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty,
              a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return 0 }
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
