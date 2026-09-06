import AVFoundation
import XCTest
@testable import Transcript

@MainActor
final class AudioPlaybackRecordingStateTests: XCTestCase {
    func testPlayingAudioStopsWhenRecordingBeginsAndCannotSeekWhileActive() throws {
        let url = try makeToneFile()
        var recording = false
        let playback = AudioPlaybackModel(
            url: url,
            durationMs: 250,
            recordingIsActive: { recording }
        )
        XCTAssertEqual(playback.availability, .ready)

        playback.play()
        recording = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(playback.isPlaying)
        let before = playback.currentTimeMs
        playback.seekAndPlay(toMs: 100)
        XCTAssertEqual(playback.currentTimeMs, before)

        recording = false
        playback.seekAndPlay(toMs: 100)
        XCTAssertEqual(playback.currentTimeMs, 100)
        playback.stop()
        try? FileManager.default.removeItem(at: url)
    }

    private func makeToneFile() throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("review-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("review-tone.wav")
        let sampleRate: UInt32 = 8_000
        let samples = Array(repeating: Int16(0), count: 2_000)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + samples.count * 2), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(sampleRate, to: &data)
        appendLE(sampleRate * 2, to: &data)
        appendLE(UInt16(2), to: &data)
        appendLE(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(samples.count * 2), to: &data)
        for sample in samples { appendLE(UInt16(bitPattern: sample), to: &data) }
        try data.write(to: url)
        return url
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
