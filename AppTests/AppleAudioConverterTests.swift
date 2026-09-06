import AVFoundation
import Synchronization
import XCTest
@testable import Transcript
import TranscriptCore

final class AppleAudioConverterTests: XCTestCase {
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
