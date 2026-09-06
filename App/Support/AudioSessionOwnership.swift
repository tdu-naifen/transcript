import AVFoundation
import Observation

@MainActor
protocol PlaybackSessionControlling {
    func activate() throws
    func deactivate() throws
}

@MainActor
private struct SystemPlaybackSession: PlaybackSessionControlling {
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Serializes all app playback ownership before capture can touch AVAudioSession.
/// A stale detail can neither acquire nor release the recorder's session.
@MainActor
@Observable
final class AudioSessionOwnership {
    static let shared = AudioSessionOwnership()

    private(set) var isCaptureReserved = false
    private let session: any PlaybackSessionControlling
    private var playbackOwner: UUID?
    private var stopPlayback: (() -> Void)?

    init(session: (any PlaybackSessionControlling)? = nil) {
        self.session = session ?? SystemPlaybackSession()
    }

    func acquirePlayback(owner: UUID, stop: @escaping () -> Void) throws -> Bool {
        guard !isCaptureReserved else { return false }
        if playbackOwner == owner { return true }
        try revokePlayback()
        playbackOwner = owner
        stopPlayback = stop
        do {
            try session.activate()
            return true
        } catch {
            try? revokePlayback()
            throw error
        }
    }

    func releasePlayback(owner: UUID) {
        guard !isCaptureReserved, playbackOwner == owner else { return }
        try? revokePlayback()
    }

    func prepareForCapture() throws {
        // Failure to deactivate is a startup failure, never permission to capture
        // while an old player still owns the process-wide audio session.
        try revokePlayback()
        isCaptureReserved = true
    }

    func releaseCapture() {
        // CaptureEngine has already stopped/deactivated its own session.
        isCaptureReserved = false
    }

    private func revokePlayback() throws {
        guard playbackOwner != nil else { return }
        stopPlayback?()
        try session.deactivate()
        playbackOwner = nil
        stopPlayback = nil
    }
}
