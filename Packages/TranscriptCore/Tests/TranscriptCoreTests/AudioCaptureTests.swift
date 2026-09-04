import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import TranscriptCore

@Suite struct AudioChunkBufferTests {
    @Test func tierFrameCountFollowsSampleRate() {
        #expect(AudioChunkTier.nemotron2240ms.frameCount(sampleRate: 16_000) == 35_840)
        #expect(AudioChunkTier(milliseconds: 80).frameCount(sampleRate: 16_000) == 1_280)
        #expect(AudioChunkTier(milliseconds: 2240).frameCount(sampleRate: 48_000) == 107_520)
    }

    @Test func emitsChunksOfExactlyTheTierSize() {
        var buffer = AudioChunkBuffer(tier: .nemotron2240ms)
        let tier = buffer.frameCount

        #expect(buffer.append([Float](repeating: 0.1, count: tier - 1)).isEmpty)
        let chunks = buffer.append([Float](repeating: 0.1, count: 1))
        #expect(chunks.count == 1)
        #expect(chunks[0].frameCount == tier)
        #expect(chunks[0].durationMs == 2240)
    }

    @Test func chunksAreInOrderAndDoNotOverlap() {
        var buffer = AudioChunkBuffer(frameCount: 100)
        var emitted: [AudioChunk] = []
        var next: Float = 0
        // Ragged input sizes, so chunk boundaries never line up with append boundaries.
        for size in [37, 250, 1, 99, 640, 3] {
            let samples = (0..<size).map { _ -> Float in
                defer { next += 1 }
                return next
            }
            emitted.append(contentsOf: buffer.append(samples))
        }
        if let final = buffer.flush() { emitted.append(final) }

        #expect(emitted.map(\.index) == Array(0..<emitted.count))
        var expectedStart = 0
        var reassembled: [Float] = []
        for chunk in emitted {
            #expect(chunk.startFrame == expectedStart)
            expectedStart += chunk.frameCount
            reassembled.append(contentsOf: chunk.samples)
        }
        #expect(reassembled == (0..<1030).map(Float.init))
        #expect(emitted.dropLast().allSatisfy { $0.frameCount == 100 })
    }

    @Test func flushProducesShorterFinalChunk() throws {
        var buffer = AudioChunkBuffer(frameCount: 100)
        _ = buffer.append([Float](repeating: 0, count: 250))
        let flushed = buffer.flush()
        let final = try #require(flushed)

        #expect(final.frameCount == 50)
        #expect(final.isFinal)
        #expect(final.index == 2)
        #expect(final.startFrame == 200)
        #expect(buffer.flush() == nil)
    }

    @Test func flushIsNilOnATierBoundaryButFinishStillTerminates() {
        var buffer = AudioChunkBuffer(frameCount: 100)
        _ = buffer.append([Float](repeating: 0, count: 200))

        #expect(buffer.flush() == nil)
        let terminator = buffer.finish()
        #expect(terminator.isFinal)
        #expect(terminator.frameCount == 0)
        #expect(terminator.startFrame == 200)
    }

    @Test func totalFrameCountCountsPendingSamples() {
        var buffer = AudioChunkBuffer(frameCount: 100)
        _ = buffer.append([Float](repeating: 0, count: 150))
        #expect(buffer.totalFrameCount == 150)
        #expect(buffer.pendingFrameCount == 50)
    }
}

@Suite struct AudioResamplerTests {
    @Test func expectedFrameCountIsRateRatio() {
        #expect(AudioResampler.expectedFrameCount(inputFrameCount: 48_000, from: 48_000, to: 16_000) == 16_000)
        #expect(AudioResampler.expectedFrameCount(inputFrameCount: 1024, from: 44_100, to: 16_000) == 372)
        #expect(AudioResampler.expectedFrameCount(inputFrameCount: 0, from: 48_000, to: 16_000) == 0)
    }

    @Test func downsamplesToSixteenKilohertzMono() throws {
        let input = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        ))
        let resampler = try AudioResampler(inputFormat: input)
        #expect(resampler.outputFormat.sampleRate == 16_000)
        #expect(resampler.outputFormat.channelCount == 1)

        var produced = 0
        for block in 0..<10 {
            produced += try resampler.resample(makeSineBuffer(format: input, frames: 4_800, startFrame: block * 4_800)).count
        }
        // The converter holds tens of milliseconds in its filter; `drain` recovers them
        // so the tail of a recording is not lost.
        let held = try resampler.drain().count
        #expect(held > 0)

        // One second of 48 kHz stereo in, one second of 16 kHz mono out.
        #expect(abs((produced + held) - 16_000) <= 16)
    }

    @Test func emptyInputProducesNoSamples() throws {
        let input = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false
        ))
        let resampler = try AudioResampler(inputFormat: input)
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 64))
        #expect(try resampler.resample(empty).isEmpty)
    }
}

@Suite struct AudioLevelTests {
    @Test func measuresRmsAndPeak() {
        let level = AudioLevel.measure([0.5, -0.5, 0.5, -0.5])
        #expect(abs(level.rms - 0.5) < 0.0001)
        #expect(abs(level.peak - 0.5) < 0.0001)
        #expect(level.normalized > 0.7 && level.normalized < 0.9)
    }

    @Test func silenceSitsOnTheFloor() {
        #expect(AudioLevel.measure([]) == .silence)
        #expect(AudioLevel.measure([0, 0, 0]).decibels == AudioLevel.floorDecibels)
        #expect(AudioLevel.measure([0, 0, 0]).normalized == 0)
    }
}

@Suite struct IncrementalSHA256Tests {
    @Test func incrementalDigestMatchesHashingTheWholeThingAtOnce() {
        let blocks: [Data] = (0..<64).map { index in
            var bytes = [UInt8]()
            for i in 0...(index * 37) {
                bytes.append(UInt8((i + index) % 251))
            }
            return Data(bytes)
        }
        var incremental = IncrementalSHA256()
        for block in blocks { incremental.update(block) }
        let whole = blocks.reduce(into: Data()) { $0.append($1) }

        #expect(incremental.byteCount == whole.count)
        #expect(incremental.finalize() == IncrementalSHA256.hex(SHA256.hash(data: whole)))
    }

    @Test func emptyInputMatchesTheEmptyDigest() {
        var hasher = IncrementalSHA256()
        hasher.update(Data())
        #expect(hasher.byteCount == 0)
        #expect(hasher.finalize() == IncrementalSHA256.hex(SHA256.hash(data: Data())))
    }

    @Test func fileHashMatchesCryptoKitOverTheSameBytes() throws {
        var raw = [UInt8]()
        raw.reserveCapacity(3 * (1 << 20) + 17)
        for i in 0..<(3 * (1 << 20) + 17) {
            raw.append(UInt8(i % 256))
        }
        let bytes = Data(raw)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Small read window, so the streaming path really does span many updates.
        let hashed = try IncrementalSHA256.hashFile(at: url, chunkBytes: 4_096)
        #expect(hashed.byteCount == bytes.count)
        #expect(hashed.sha256 == IncrementalSHA256.hex(SHA256.hash(data: bytes)))
    }
}

@Suite struct AudioFileStoreTests {
    @Test func namesFilesByMeetingId() throws {
        let store = AudioFileStore(directory: URL(fileURLWithPath: "/tmp/audio"))
        let id = UUID().uuidString
        #expect(try store.fileName(for: id) == "\(id).m4a")
        #expect(try store.url(for: id).lastPathComponent == "\(id).m4a")
    }

    @Test func rejectsNamesThatCouldEscapeTheDirectory() {
        let store = AudioFileStore(directory: URL(fileURLWithPath: "/tmp/audio"))
        #expect(throws: AudioCaptureError.self) { try store.url(forFileName: "../../etc/passwd") }
        #expect(throws: AudioCaptureError.self) { try store.fileName(for: "") }
    }
}

@Suite struct AudioFileWriterTests {
    @Test func writesPlayableM4AAndHashesItWhileWriting() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.m4a")

        let writer = try AudioFileWriter(url: url, segmentSeconds: 1)
        try writer.start()
        let format = AudioCaptureFormat.makeProcessingFormat()
        var buffer = AudioChunkBuffer(tier: .nemotron2240ms)
        for block in 0..<4 {
            let samples = try sineSamples(format: format, frames: 16_000, startFrame: block * 16_000)
            for chunk in buffer.append(samples) {
                try await writer.append(chunk)
            }
        }
        try await writer.append(buffer.finish())
        let sealed = try await writer.finish()

        let onDisk = try Data(contentsOf: url)
        #expect(sealed.byteCount == onDisk.count)
        #expect(sealed.byteCount > 0)
        // The point of the fragmented writer: the bytes hashed during writing are the
        // bytes that ended up on disk, with no second pass over the file.
        #expect(sealed.sha256 == IncrementalSHA256.hex(SHA256.hash(data: onDisk)))
        #expect(sealed.fileName == "recording.m4a")

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.fileFormat.sampleRate == 16_000)
        #expect(readBack.length > 60_000)
    }
}

// MARK: - Helpers

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sineSamples(format: AVAudioFormat, frames: Int, startFrame: Int) throws -> [Float] {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let channel = try #require(buffer.floatChannelData)[0]
    for i in 0..<frames {
        channel[i] = sin(Float(startFrame + i) * 0.05) * 0.4
    }
    return Array(UnsafeBufferPointer(start: channel, count: frames))
}

func makeSineBuffer(format: AVAudioFormat, frames: Int, startFrame: Int) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<Int(format.channelCount) {
        for i in 0..<frames {
            channels[channel][i] = sin(Float(startFrame + i) * 0.05) * 0.4
        }
    }
    return buffer
}
