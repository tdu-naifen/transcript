import AVFoundation
import Foundation

/// Converts whatever the input node hands us into 16 kHz mono Float32.
///
/// Not `Sendable` on purpose: one instance belongs to one tap, and `AVAudioConverter`
/// carries resampling filter state that must stay on that single producer.
public final class AudioResampler {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    public convenience init(
        inputFormat: AVAudioFormat,
        sampleRate: Double = AudioCaptureFormat.sampleRate
    ) throws {
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AudioCaptureFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidInputFormat
        }
        try self.init(inputFormat: inputFormat, outputFormat: output)
    }

    /// Frames a rate conversion is expected to produce, rounded up so a fractional
    /// trailing frame is still allocated for.
    public static func expectedFrameCount(
        inputFrameCount: Int,
        from inputRate: Double,
        to outputRate: Double
    ) -> Int {
        guard inputFrameCount > 0, inputRate > 0, outputRate > 0 else { return 0 }
        return Int((Double(inputFrameCount) * outputRate / inputRate).rounded(.up))
    }

    public func resample(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let expected = Self.expectedFrameCount(
            inputFrameCount: Int(buffer.frameLength),
            from: inputFormat.sampleRate,
            to: outputFormat.sampleRate
        )
        // Slack absorbs the converter flushing frames it held back on a previous call.
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(expected + 1024)
        ) else {
            throw AudioCaptureError.bufferAllocationFailed
        }

        let source = InputBox(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard let next = source.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }

        if status == .error {
            throw AudioCaptureError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown conversion failure"
            )
        }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Frames the converter is still holding in its resampling filter (tens of
    /// milliseconds). Called once when capture ends, so the tail of a recording is not
    /// silently dropped. The resampler must not be used afterwards.
    public func drain() throws -> [Float] {
        var drained: [Float] = []
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else {
                throw AudioCaptureError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error else {
                throw AudioCaptureError.conversionFailed(
                    conversionError?.localizedDescription ?? "unknown conversion failure"
                )
            }
            guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { break }
            drained.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if status == .endOfStream { break }
        }
        return drained
    }
}

/// Hands the pending input buffer to the converter exactly once per `convert` call.
private final class InputBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
