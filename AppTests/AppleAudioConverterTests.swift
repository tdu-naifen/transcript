import AVFoundation
import Synchronization
import XCTest
@testable import Transcript
import TranscriptCore

final class AppleAudioConverterTests: XCTestCase {
    func testFileAnalyzerInputExcludesAACPaddingAndDrainsConvertedTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.m4a")
        let writer = try AudioFileWriter(url: url, segmentSeconds: 1)
        try writer.start()
        let samples = (0..<16_000).map { Float(sin(Double($0) * 0.07) * 0.1) }
        for chunk in AudioFileLoader.chunks(from: samples) { try await writer.append(chunk) }
        let sealed = try await writer.finish()
        for rate in [16_000.0, 48_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let input = try AppleFileAudioInput(url: url, durationMs: 1000, outputFormat: format)
            var frameCount = 0
            while let next = try await input.next() {
                XCTAssertEqual(next.buffer.format, format)
                frameCount += Int(next.buffer.frameLength)
            }
            XCTAssertEqual(frameCount, Int(rate))
            let exhausted = try await input.next()
            XCTAssertNil(exhausted)
        }
        XCTAssertEqual(try IncrementalSHA256.hashFile(at: url).sha256, sealed.sha256)
    }

    func testConcurrentCallbacksReceiveInputExactlyOnce() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let source = AppleAudioConverter.AppleConverterInput(buffer: AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        let deliveries = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if source.take() != nil {
                deliveries.withLock { $0 += 1 }
            }
        }
        XCTAssertEqual(deliveries.withLock { $0 }, 1)
        XCTAssertNil(source.take())
    }

    func testConversionPreservesChunkContinuityAndFlushesTail() throws {
        for rate in [16_000.0, 48_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let converter = try AppleAudioConverter(outputFormat: format)
            let samples = (0..<32_123).map { Float(sin(Double($0) * 0.07) * 0.1) }
            var converted: [Float] = []
            for chunk in AudioFileLoader.chunks(from: samples) {
                if let buffer = try converter.convert(chunk) {
                    let data = try XCTUnwrap(buffer.floatChannelData?[0])
                    converted.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                }
            }
            if let tail = try converter.finish() {
                let data = try XCTUnwrap(tail.floatChannelData?[0])
                converted.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(tail.frameLength)))
            }
            XCTAssertEqual(converted.count, Int(Double(samples.count) * rate / 16_000))
            XCTAssertTrue(converted.allSatisfy { $0.isFinite })
            XCTAssertGreaterThan(converted.map { abs($0) }.max() ?? 0, 0.05)
        }
    }
}
