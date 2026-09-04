import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Audio bytes as they were sealed onto disk (PLAN §3.4 / §9.4.1).
public struct SealedAudio: Sendable, Hashable {
    public let fileName: String
    public let sha256: String
    public let byteCount: Int

    public init(fileName: String, sha256: String, byteCount: Int) {
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Writes captured audio to an M4A (AAC) file and hashes it as it goes.
///
/// It writes *fragmented* MP4 via `AVAssetWriter`'s segment delegate rather than
/// `AVAudioFile`, for two reasons:
///
/// 1. `AVAudioFile` reserves a `moov` box at the head of the file and patches it on
///    close, so bytes already written change afterwards — a hash accumulated during
///    writing would be wrong, and the file would have to be re-read to fix it.
///    Fragment bytes are final the moment they are handed over.
/// 2. A fragmented file that was never finalized is still playable up to its last
///    whole fragment, which is exactly what crash salvage needs (PLAN §3.2.1).
public final class AudioFileWriter: @unchecked Sendable {
    public let url: URL
    public let fileName: String

    private let lock = NSLock()
    private let delegateQueue = DispatchQueue(label: "com.transcript.audio-file-writer")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let sink: SegmentSink
    private let sampleRate: Double
    private var started = false
    private var finished = false
    private var endFrame: Int = 0

    public init(
        url: URL,
        sampleRate: Double = AudioCaptureFormat.sampleRate,
        bitRate: Int = 32_000,
        segmentSeconds: Double = 5
    ) throws {
        self.url = url
        self.fileName = url.lastPathComponent
        self.sampleRate = sampleRate
        self.sink = try SegmentSink(url: url)

        writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.shouldOptimizeForNetworkUse = false

        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(AudioCaptureFormat.channelCount),
            AVEncoderBitRateKey: bitRate
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw AudioCaptureError.writerUnavailable("AAC input rejected")
        }
        writer.add(input)
        writer.delegate = sink
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        guard writer.startWriting() else {
            throw AudioCaptureError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    /// Appends one chunk. Back-pressure from the encoder is awaited rather than
    /// dropped: losing audio is not an acceptable failure mode (PLAN §3.2.1).
    public func append(_ chunk: AudioChunk) async throws {
        guard !chunk.samples.isEmpty else {
            lock.withLock { endFrame = max(endFrame, chunk.startFrame) }
            return
        }
        for _ in 0..<400 {
            if lock.withLock({ input.isReadyForMoreMediaData }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try lock.withLock {
            guard started, !finished else { throw AudioCaptureError.notRecording }
            guard writer.status == .writing else {
                throw AudioCaptureError.writerFailed(writer.error?.localizedDescription ?? "writer stopped")
            }
            guard let buffer = Self.makeSampleBuffer(chunk) else {
                throw AudioCaptureError.bufferAllocationFailed
            }
            guard input.append(buffer) else {
                throw AudioCaptureError.writerFailed(writer.error?.localizedDescription ?? "append rejected")
            }
            endFrame = max(endFrame, chunk.startFrame + chunk.frameCount)
        }
    }

    public func finish() async throws -> SealedAudio {
        try lock.withLock {
            guard started, !finished else { throw AudioCaptureError.notRecording }
            finished = true
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(
                value: CMTimeValue(endFrame), timescale: CMTimeScale(sampleRate)
            ))
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw AudioCaptureError.writerFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }
        return try sink.seal(fileName: fileName)
    }

    /// Stops encoding but keeps whatever fragments already reached the disk.
    public func abandon() {
        lock.withLock {
            guard started, !finished else { return }
            finished = true
            writer.cancelWriting()
        }
        sink.close()
    }

    private static func makeSampleBuffer(_ chunk: AudioChunk) -> CMSampleBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.sampleRate,
            channels: AudioCaptureFormat.channelCount,
            interleaved: false
        ),
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frameCount)),
        let channel = pcm.floatChannelData?[0] else { return nil }
        pcm.frameLength = AVAudioFrameCount(chunk.frameCount)
        chunk.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: chunk.frameCount)
        }

        var description: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, let description else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(chunk.sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(chunk.startFrame), timescale: CMTimeScale(chunk.sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(chunk.frameCount),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            bufferList: pcm.audioBufferList
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

/// Receives fMP4 segments in order and both writes and hashes them in one pass.
private final class SegmentSink: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hasher = IncrementalSHA256()
    private var failure: (any Error)?

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AudioCaptureError.writerUnavailable("cannot create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        super.init()
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, failure == nil else { return }
        do {
            try handle.write(contentsOf: segmentData)
            hasher.update(segmentData)
        } catch {
            failure = error
        }
    }

    func seal(fileName: String) throws -> SealedAudio {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw AudioCaptureError.writerFailed(failure.localizedDescription) }
        try handle?.close()
        handle = nil
        let byteCount = hasher.byteCount
        return SealedAudio(fileName: fileName, sha256: hasher.finalize(), byteCount: byteCount)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
