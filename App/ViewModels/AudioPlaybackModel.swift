import AVFoundation
import Foundation
import Observation

/// Local playback for a meeting recording (UI.md §3). The audio file may be missing
/// from disk — PLAN §3.4 allows local audio to be purged once Mac has verified its
/// copy — so this degrades to `.unavailable` instead of crashing or presenting a
/// player that silently does nothing.
@MainActor
@Observable
final class AudioPlaybackModel {
    enum Availability: Equatable {
        case ready
        case unavailable(reason: String)
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
    /// Authoritative duration (PLAN §3.3.2 — captured frame count, not container
    /// duration), shown even when the file itself is unavailable.
    let durationMs: Int
    private(set) var speed: Speed = .normal

    private let player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    init(url: URL?, durationMs: Int) {
        self.durationMs = durationMs
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            self.player = nil
            self.availability = .unavailable(reason: url == nil
                ? "这场会议没有关联的音频文件。"
                : "本地音频已不在此设备上（可能已同步至 Mac 并被清理）。")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            self.player = player
            self.availability = .ready
        } catch {
            self.player = nil
            self.availability = .unavailable(reason: "无法打开音频文件。")
        }
    }

    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return Double(currentTimeMs) / Double(durationMs)
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player, !player.isPlaying else { return }
        activateSession()
        player.rate = Float(speed.rawValue)
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    /// Seeks and plays (UI.md §3b: "Tapping any line seeks the player to that line's
    /// startMs and plays").
    func seekAndPlay(toMs ms: Int) {
        seek(toMs: ms)
        play()
    }

    func seek(toMs ms: Int) {
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

    /// `.playback` (not `.playAndRecord`) so this works with the silent switch on and
    /// never competes with `AudioCaptureEngine`'s recording session (UI.md §3a).
    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: [])
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}
