import AVFoundation
import Foundation
import Observation

/// Local playback for a meeting recording. If its audio file is missing from disk,
/// this degrades to `.unavailable` instead of crashing or presenting a player that
/// silently does nothing.
@MainActor
@Observable
final class AudioPlaybackModel {
    enum Availability: Equatable {
        case ready
        case unavailable(reason: UnavailableReason)
    }

    /// Kept as data rather than a pre-resolved `String`: `AudioPlayerBar` reads
    /// `.text` at render time, so the message re-localizes if the app language
    /// changes while this screen is showing a degraded player.
    enum UnavailableReason: Equatable {
        case noAudioFile
        case localAudioMissing
        case openFailed
        case recordingInProgress
        case playbackFailed

        @MainActor
        var text: String {
            let localization = LocalizationManager.shared
            switch self {
            case .noAudioFile:
                return localization.localized("This meeting has no associated audio file.")
            case .localAudioMissing:
                return localization.localized("The audio file is not available on this device. The transcript is still available.")
            case .openFailed:
                return localization.localized("Couldn't open the audio file.")
            case .recordingInProgress:
                return localization.localized("Stop the active recording before playing another meeting.")
            case .playbackFailed:
                return localization.localized("Couldn't start audio playback. Reopen this meeting to try again.")
            }
        }
    }

    enum Speed: Double, CaseIterable {
        case normal = 1.0
        case fast = 1.5
        case faster = 2.0

        var label: String {
            switch self {
            case .normal: "1x"
            case .fast: "1.5x"
            case .faster: "2x"
            }
        }

        var next: Speed {
            switch self {
            case .normal: .fast
            case .fast: .faster
            case .faster: .normal
            }
        }
    }

    private(set) var availability: Availability
    private(set) var isPlaying = false
    private(set) var currentTimeMs = 0
    /// Authoritative duration from captured frames, not container duration,
    /// shown even when the file itself is unavailable.
    let durationMs: Int
    private(set) var speed: Speed = .normal
    private(set) var waveform: [Float] = []

    private let player: AVAudioPlayer?
    private let recordingIsActive: @MainActor () -> Bool
    private var ticker: Task<Void, Never>?
    private let audioOwnership: AudioSessionOwnership
    private let ownerID = UUID()

    init(
        url: URL?,
        durationMs: Int,
        isRecordingActive: Bool = false,
        recordingIsActive: (@MainActor () -> Bool)? = nil,
        audioOwnership: AudioSessionOwnership = .shared
    ) {
        self.durationMs = durationMs
        self.recordingIsActive = recordingIsActive ?? { isRecordingActive }
        self.audioOwnership = audioOwnership
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            self.player = nil
            self.availability = .unavailable(reason: url == nil ? .noAudioFile : .localAudioMissing)
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            self.player = player
            self.availability = .ready
            Task { [weak self] in
                self?.waveform = await Self.loadWaveform(url: url)
            }
        } catch {
            self.player = nil
            self.availability = .unavailable(reason: .openFailed)
        }
    }

    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return Double(currentTimeMs) / Double(durationMs)
    }

    var isInteractionBlockedByRecording: Bool { audioOwnership.isCaptureReserved || recordingIsActive() }

    func togglePlayPause() {
        guard !isInteractionBlockedByRecording else { return }
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !isInteractionBlockedByRecording else { return }
        guard availability == .ready, let player, !player.isPlaying else { return }
        do {
            guard try audioOwnership.acquirePlayback(owner: ownerID, stop: { [weak self] in
                self?.pause()
            }) else { return }
            player.rate = Float(speed.rawValue)
            guard player.play() else {
                availability = .unavailable(reason: .playbackFailed)
                deactivateSession()
                return
            }
            isPlaying = true
            startTicking()
        } catch {
            availability = .unavailable(reason: .playbackFailed)
            deactivateSession()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    /// Tapping a transcript line seeks to its start time and plays.
    func seekAndPlay(toMs ms: Int) {
        guard !isInteractionBlockedByRecording else { return }
        seek(toMs: ms)
        play()
    }

    func seek(toMs ms: Int) {
        guard !isInteractionBlockedByRecording else { return }
        guard let player else { return }
        let clamped = max(0, min(ms, durationMs))
        player.currentTime = Double(clamped) / 1000
        currentTimeMs = clamped
    }

    func skip(_ deltaSeconds: Double) {
        seek(toMs: currentTimeMs + Int(deltaSeconds * 1000))
    }

    func cycleSpeed() {
        speed = speed.next
        player?.rate = Float(speed.rawValue)
    }

    /// Called when the detail screen disappears, so playback doesn't keep running (and
    /// holding the audio session) once the user has navigated away.
    func stop() {
        pause()
        deactivateSession()
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if self.isInteractionBlockedByRecording {
                    self.pause()
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { break }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        currentTimeMs = Int(player.currentTime * 1000)
        if !player.isPlaying {
            // Either paused elsewhere or reached the end of the file; either way there's
            // nothing left to poll for.
            isPlaying = false
            ticker?.cancel()
        }
    }

    private func deactivateSession() {
        audioOwnership.releasePlayback(owner: ownerID)
    }

    private nonisolated static func loadWaveform(url: URL, barCount: Int = 84) async -> [Float] {
        await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
            let format = file.processingFormat
            let framesPerBar = max(1, Int(file.length) / barCount)
            let capacity = AVAudioFrameCount(min(16_384, max(1, framesPerBar)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }

            var sums = [Double](repeating: 0, count: barCount)
            var counts = [Int](repeating: 0, count: barCount)
            var sourceFrame = 0

            while file.framePosition < file.length {
                do {
                    try file.read(into: buffer)
                } catch {
                    return []
                }
                guard let channels = buffer.floatChannelData else { return [] }
                let frameCount = Int(buffer.frameLength)
                for frame in 0..<frameCount {
                    let bar = min(barCount - 1, (sourceFrame + frame) / framesPerBar)
                    var amplitude: Float = 0
                    for channel in 0..<Int(format.channelCount) {
                        amplitude = max(amplitude, abs(channels[channel][frame]))
                    }
                    sums[bar] += Double(amplitude)
                    counts[bar] += 1
                }
                sourceFrame += frameCount
            }

            let raw = zip(sums, counts).map { sum, count in
                count == 0 ? Float(0) : Float(sum / Double(count))
            }
            guard let peak = raw.max(), peak > 0 else { return raw }
            return raw.map { max(0.08, min(1, $0 / peak)) }
        }.value
    }
}
