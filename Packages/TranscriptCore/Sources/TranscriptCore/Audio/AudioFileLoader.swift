import AVFoundation
import Foundation

/// Decodes an audio file into the same 16 kHz mono Float32 the capture pipeline
/// produces, so file-driven runs and microphone runs feed the engine identical data.
public enum AudioFileLoader {
    public static func load16kMono(
        url: URL,
        maxSeconds: Double? = nil
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let resampler = try AudioResampler(inputFormat: file.processingFormat)

        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.bufferAllocationFailed
        }

        let limit = maxSeconds.map { Int(($0 * AudioCaptureFormat.sampleRate).rounded()) }
        var samples: [Float] = []
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(Int64(capacity), file.length - file.framePosition))
            guard remaining > 0 else { break }
            try file.read(into: buffer, frameCount: remaining)
            if buffer.frameLength == 0 { break }
            samples.append(contentsOf: try resampler.resample(buffer))
            if let limit, samples.count >= limit { break }
        }
        // The converter holds tens of milliseconds in its filter; without this the
        // tail of the file is silently lost.
        samples.append(contentsOf: try resampler.drain())

        if let limit, samples.count > limit { samples.removeLast(samples.count - limit) }
        return samples
    }

    /// Cuts a sample buffer into tier-aligned chunks exactly as ``AudioChunkBuffer``
    /// does live, including the zero-length terminator.
    public static func chunks(
        from samples: [Float],
        tier: AudioChunkTier = .nemotron2240ms,
        sampleRate: Double = AudioCaptureFormat.sampleRate
    ) -> [AudioChunk] {
        var buffer = AudioChunkBuffer(tier: tier, sampleRate: sampleRate)
        var chunks = buffer.append(samples)
        chunks.append(buffer.finish())
        return chunks
    }
}
