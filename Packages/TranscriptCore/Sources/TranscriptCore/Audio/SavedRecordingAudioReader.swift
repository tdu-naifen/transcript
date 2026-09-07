import AVFoundation
import Foundation

/// Reads the sealed capture interval, excluding a partial AAC packet's decoded tail.
public final class SavedRecordingAudioReader {
    public enum Failure: Error, Sendable { case inconsistentDuration, unexpectedEnd }

    public let format: AVAudioFormat
    public let frameCount: AVAudioFramePosition
    private let file: AVAudioFile

    public init(url: URL, durationMs: Int) throws {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let expected = (Double(durationMs) * rate / 1000).rounded()
        guard durationMs > 0, rate.isFinite, rate > 0,
              expected > 0, expected < Double(Int64.max), file.length > 0 else {
            throw Failure.inconsistentDuration
        }
        let expectedFrames = AVAudioFramePosition(expected)
        let roundingFrames = (rate / 2000).rounded(.up)
        let description = file.fileFormat.streamDescription.pointee
        let packetFrames = description.mFormatID == kAudioFormatMPEG4AAC
            ? Double(description.mFramesPerPacket) : 0
        let difference = Double(file.length) - Double(expectedFrames)
        // A larger discrepancy is not codec padding. Do not silently crop a stale
        // duration, extend a short file, or change persisted capture metadata.
        guard difference >= -roundingFrames,
              difference < max(1, packetFrames) + roundingFrames else {
            throw Failure.inconsistentDuration
        }
        self.file = file
        self.format = file.processingFormat
        self.frameCount = min(expectedFrames, file.length)
    }

    public func read() throws -> sending AVAudioPCMBuffer? {
        try Task.checkCancellation()
        let remaining = frameCount - file.framePosition
        guard remaining > 0 else { return nil }
        let count = AVAudioFrameCount(min(16_384, remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0 else { throw Failure.unexpectedEnd }
        return buffer
    }
}
