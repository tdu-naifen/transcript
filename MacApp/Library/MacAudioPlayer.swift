import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MacAudioPlayer {
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isAvailable = false
    private(set) var errorMessage: String?

    var isLoaded: Bool { isAvailable }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: PlaybackDelegate?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var playbackGeneration = 0

    func load(url: URL) {
        load(url: Optional(url))
    }

    func load(url: URL?) {
        unload()
        guard let url else {
            errorMessage = MacLibraryError.audioUnavailable.localizedDescription
            return
        }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            guard audio.duration.isFinite, audio.duration > 0, audio.prepareToPlay() else {
                throw MacLibraryError.invalidAudio
            }
            player = audio
            duration = audio.duration
            isAvailable = true
        } catch {
            errorMessage = String(localized: "The audio file could not be opened.")
                + "\n" + error.localizedDescription
        }
    }

    func play() {
        guard let player, isAvailable else {
            errorMessage = MacLibraryError.audioUnavailable.localizedDescription
            return
        }
        guard !isPlaying else { return }
        if currentTime >= duration { player.currentTime = 0 }
        playbackGeneration += 1
        let delegate = PlaybackDelegate(owner: self, generation: playbackGeneration)
        player.delegate = delegate
        self.delegate = delegate
        guard player.play() else {
            errorMessage = String(localized: "Audio playback could not be started.")
            return
        }
        errorMessage = nil
        currentTime = player.currentTime
        isPlaying = true
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self else { return }
                self.updateProgress()
            }
        }
    }

    func pause() {
        playbackGeneration += 1
        player?.pause()
        currentTime = player?.currentTime ?? 0
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func togglePlayback() {
        togglePlayPause()
    }

    func seek(to time: TimeInterval) {
        guard let player, time.isFinite else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        playbackGeneration += 1
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
    }

    func unload() {
        stop()
        player?.delegate = nil
        player = nil
        delegate = nil
        duration = 0
        isAvailable = false
        errorMessage = nil
    }

    private func updateProgress() {
        guard let player else { return }
        currentTime = min(max(0, player.currentTime), duration)
        isPlaying = player.isPlaying
        if !isPlaying {
            ticker?.cancel()
            ticker = nil
        }
    }

    fileprivate func finished(
        playerID: ObjectIdentifier,
        generation: Int,
        successfully: Bool,
        failureReason: String? = nil
    ) {
        guard generation == playbackGeneration,
              let player, ObjectIdentifier(player) == playerID else { return }
        ticker?.cancel()
        ticker = nil
        isPlaying = false
        currentTime = successfully ? duration : player.currentTime
        if !successfully {
            errorMessage = String(localized: "Audio playback failed.")
            if let failureReason { errorMessage? += "\n" + failureReason }
        }
    }

    isolated deinit {
        ticker?.cancel()
        player?.stop()
    }
}

@MainActor
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    weak var owner: MacAudioPlayer?
    nonisolated let generation: Int

    init(owner: MacAudioPlayer, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.finished(playerID: playerID, generation: self.generation, successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let playerID = ObjectIdentifier(player)
        let reason = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.finished(
                playerID: playerID, generation: self.generation,
                successfully: false, failureReason: reason
            )
        }
    }
}
