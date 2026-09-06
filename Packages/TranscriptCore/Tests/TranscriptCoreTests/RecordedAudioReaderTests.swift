import AVFoundation
import Foundation
import Testing
@testable import TranscriptCore

struct RecordedAudioReaderTests {
    @Test(arguments: ["wav", "m4a"])
    func demandDrivenReaderPreservesFinalSamplesAndBoundsChunkSize(fileExtension: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_123))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { channel[index] = Float(sin(Double(index) * 0.1) * 0.1) }
        do {
            let settings: [String: Any] = fileExtension == "wav" ? format.settings : [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        let reader = try RecordedAudioReader(url: url)
        var total = 0
        var sawFinal = false
        while let chunk = await reader.next() {
            #expect(chunk.startFrame == total)
            #expect(chunk.samples.count <= AudioChunkTier.nemotron2240ms.frameCount(sampleRate: 16_000))
            total += chunk.samples.count
            sawFinal = sawFinal || chunk.isFinal
        }
        try await reader.checkFailure()
        let reference = try AudioFileLoader.load16kMono(url: url)
        #expect(total == reference.count)
        if fileExtension == "wav" { #expect(total == 80_123) }
        #expect(sawFinal)
    }
}
