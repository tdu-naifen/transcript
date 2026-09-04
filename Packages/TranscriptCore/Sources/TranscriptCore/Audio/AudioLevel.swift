import Accelerate
import Foundation

/// Cheap loudness signal for the UI meter, published on its own stream so the meter
/// never has to consume the ASR chunk stream.
public struct AudioLevel: Sendable, Hashable {
    public static let floorDecibels: Float = -60

    public let rms: Float
    public let peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silence = AudioLevel(rms: 0, peak: 0)

    public var decibels: Float {
        guard rms > 0 else { return Self.floorDecibels }
        return max(Self.floorDecibels, 20 * log10(rms))
    }

    /// 0…1, suitable for a bar height.
    public var normalized: Float {
        (decibels - Self.floorDecibels) / -Self.floorDecibels
    }

    public static func measure(_ samples: [Float]) -> AudioLevel {
        guard !samples.isEmpty else { return .silence }
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return AudioLevel(rms: rms, peak: peak)
    }
}
