import AVFoundation
import Foundation

/// Demand-driven decoding keeps the full recording out of the inference queue.
public actor RecordedAudioReader {
    private let file: AVAudioFile
    private let resampler: AudioResampler
    private let buffer: AVAudioPCMBuffer
    private var chunks = AudioChunkBuffer()
    private var pending: [AudioChunk] = []
    private var ended = false
    private var failure: (any Error)?
    public private(set) var frameCount = 0

    public init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        self.file = file
        resampler = try AudioResampler(inputFormat: file.processingFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        self.buffer = buffer
    }

    public func next() -> AudioChunk? {
        do {
            try Task.checkCancellation()
            while pending.isEmpty && !ended {
                if file.framePosition < file.length {
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw AudioCaptureError.bufferAllocationFailed }
                    let samples = try resampler.resample(buffer)
                    frameCount += samples.count
                    pending.append(contentsOf: chunks.append(samples))
                } else {
                    let tail = try resampler.drain()
                    frameCount += tail.count
                    pending.append(contentsOf: chunks.append(tail))
                    pending.append(chunks.finish())
                    ended = true
                }
            }
            return pending.isEmpty ? nil : pending.removeFirst()
        } catch {
            failure = error
            ended = true
            pending.removeAll()
            return nil
        }
    }

    public func checkFailure() throws {
        if let failure { throw failure }
    }
}
