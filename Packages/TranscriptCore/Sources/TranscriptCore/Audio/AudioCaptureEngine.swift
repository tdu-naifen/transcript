import AVFoundation
import Foundation

public enum AudioCaptureEvent: Sendable, Equatable {
    case started
    case paused
    case resumed
    /// Phone call, Siri, or another app took the session. Capture is suspended, not lost.
    case interrupted
    case interruptionEnded(resumed: Bool)
    case routeChanged(reason: String, inputName: String?)
    case stopped(frameCount: Int)
    case failed(message: String)
}

public protocol AudioCaptureControlling: Sendable {
    func chunks() -> AsyncStream<AudioChunk>
    func levels() -> AsyncStream<AudioLevel>
    func events() -> AsyncStream<AudioCaptureEvent>
    func start() throws
    func pause() throws
    func resume() throws
    @discardableResult
    func stop() -> Int
    func invalidate()
}

/// Taps the input node, resamples to 16 kHz mono Float32, and publishes tier-aligned
/// chunks plus a separate low-rate level signal.
///
/// Chunk streams are broadcast: every call to ``chunks()`` gets its own stream, so the
/// file writer and a future ASR consumer can both iterate without competing. Streams
/// outlive a single recording; each recording restarts chunk indices at 0 and ends with
/// a chunk whose `isFinal` is true.
public final class AudioCaptureEngine: AudioCaptureControlling, @unchecked Sendable {
    private enum State: Sendable {
        case idle
        case running
        case paused
        case interrupted
    }

    public let configuration: AudioCaptureConfiguration

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var resampler: AudioResampler?
    private var buffer: AudioChunkBuffer
    private var state: State = .idle
    private var tapInstalled = false
    private var lastLevelAt: TimeInterval = 0
    private var chunkSinks: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]
    private var levelSinks: [UUID: AsyncStream<AudioLevel>.Continuation] = [:]
    private var eventSinks: [UUID: AsyncStream<AudioCaptureEvent>.Continuation] = [:]
    private var observers: [any NSObjectProtocol] = []

    /// What the archive stream is currently resampled to (UI §5.1). Mutable so a
    /// Settings change takes effect on the next recording without recreating the engine.
    private var archiveQuality: RecordingQuality
    private var archiveResampler: AudioResampler?
    private var archiveBuffer: AudioChunkBuffer?
    private var archiveChunkSinks: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]

    public init(configuration: AudioCaptureConfiguration = AudioCaptureConfiguration()) {
        self.configuration = configuration
        self.archiveQuality = configuration.archiveQuality
        self.buffer = AudioChunkBuffer(tier: configuration.tier, sampleRate: configuration.sampleRate)
        observeSessionNotifications()
    }

    /// Threadsafe: may be called at any time, including mid-recording (takes effect on
    /// the next `start()`).
    public func setArchiveQuality(_ quality: RecordingQuality) {
        lock.withLock { archiveQuality = quality }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Streams

    public func chunks() -> AsyncStream<AudioChunk> {
        AsyncStream(AudioChunk.self, bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            lock.withLock { chunkSinks[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = chunkSinks.removeValue(forKey: id) }
            }
        }
    }

    /// Only yields samples while `archiveQuality == .highFidelity`; empty otherwise
    /// (the file writer uses ``chunks()`` for `.voice`, UI §5.1).
    public func archiveChunks() -> AsyncStream<AudioChunk> {
        AsyncStream(AudioChunk.self, bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            lock.withLock { archiveChunkSinks[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = archiveChunkSinks.removeValue(forKey: id) }
            }
        }
    }

    /// UI meter feed. Latest value only: a slow UI must never stall capture.
    public func levels() -> AsyncStream<AudioLevel> {
        AsyncStream(AudioLevel.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { levelSinks[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = levelSinks.removeValue(forKey: id) }
            }
        }
    }

    public func events() -> AsyncStream<AudioCaptureEvent> {
        AsyncStream(AudioCaptureEvent.self, bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID()
            lock.withLock { eventSinks[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = eventSinks.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - Control

    public var isRunning: Bool { lock.withLock { state == .running } }

    public func start() throws {
        try lock.withLock {
            guard state == .idle else { throw AudioCaptureError.alreadyRecording }
            buffer = AudioChunkBuffer(tier: configuration.tier, sampleRate: configuration.sampleRate)
            lastLevelAt = 0
            try activateSession()
            try installTapLocked()
            engine.prepare()
            try engine.start()
            state = .running
            emitLocked(.started)
        }
    }

    public func pause() throws {
        try lock.withLock {
            guard state == .running else { throw AudioCaptureError.notRecording }
            engine.pause()
            state = .paused
            emitLocked(.paused)
        }
    }

    public func resume() throws {
        try lock.withLock {
            guard state == .paused || state == .interrupted else { throw AudioCaptureError.notRecording }
            try activateSession()
            try engine.start()
            state = .running
            emitLocked(.resumed)
        }
    }

    /// Ends the recording and emits the terminating chunk. Returns total captured frames.
    @discardableResult
    public func stop() -> Int {
        lock.withLock {
            guard state != .idle else { return 0 }
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            if let resampler, let tail = try? resampler.drain(), !tail.isEmpty {
                for chunk in buffer.append(tail) {
                    for sink in chunkSinks.values { sink.yield(chunk) }
                }
            }
            resampler = nil
            if let archiveResampler, let tail = try? archiveResampler.drain(), !tail.isEmpty, archiveBuffer != nil {
                for chunk in archiveBuffer!.append(tail) {
                    for sink in archiveChunkSinks.values { sink.yield(chunk) }
                }
            }
            archiveResampler = nil
            state = .idle
            let final = buffer.finish()
            let frameCount = buffer.totalFrameCount
            for sink in chunkSinks.values { sink.yield(final) }
            if var archiveBuffer {
                let archiveFinal = archiveBuffer.finish()
                for sink in archiveChunkSinks.values { sink.yield(archiveFinal) }
            }
            archiveBuffer = nil
            deactivateSession()
            emitLocked(.stopped(frameCount: frameCount))
            return frameCount
        }
    }

    /// Ends every stream. The engine is unusable afterwards.
    public func invalidate() {
        stop()
        let (chunks, archiveChunks, levels, events): (
            [AsyncStream<AudioChunk>.Continuation],
            [AsyncStream<AudioChunk>.Continuation],
            [AsyncStream<AudioLevel>.Continuation],
            [AsyncStream<AudioCaptureEvent>.Continuation]
        ) = lock.withLock {
            let result = (
                Array(chunkSinks.values), Array(archiveChunkSinks.values),
                Array(levelSinks.values), Array(eventSinks.values)
            )
            chunkSinks.removeAll()
            archiveChunkSinks.removeAll()
            levelSinks.removeAll()
            eventSinks.removeAll()
            return result
        }
        // Finishing runs `onTermination`, which takes the lock, so it happens outside it.
        for sink in chunks { sink.finish() }
        for sink in archiveChunks { sink.finish() }
        for sink in levels { sink.finish() }
        for sink in events { sink.finish() }
    }

    // MARK: - Capture

    private func installTapLocked() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }
        resampler = try AudioResampler(inputFormat: format, sampleRate: configuration.sampleRate)
        if archiveQuality == .highFidelity,
           let archiveFormat = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: archiveQuality.archiveSampleRate,
               channels: AudioCaptureFormat.channelCount,
               interleaved: false
           ) {
            archiveResampler = try AudioResampler(inputFormat: format, outputFormat: archiveFormat)
            archiveBuffer = AudioChunkBuffer(frameCount: 1, sampleRate: archiveFormat.sampleRate)
        } else {
            archiveResampler = nil
            archiveBuffer = nil
        }
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: configuration.tapBufferSize, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
    }

    /// Runs on the audio thread. Everything happens under the lock so chunks reach every
    /// consumer in capture order even if the tap is reinstalled by a route change.
    private func handleTap(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running, let resampler else { return }

        let samples: [Float]
        do {
            samples = try resampler.resample(pcm)
        } catch {
            emitLocked(.failed(message: String(describing: error)))
            return
        }
        guard !samples.isEmpty else { return }

        for chunk in buffer.append(samples) {
            for sink in chunkSinks.values { sink.yield(chunk) }
        }

        if let archiveResampler {
            let archiveSamples: [Float]
            do {
                archiveSamples = try archiveResampler.resample(pcm)
            } catch {
                emitLocked(.failed(message: String(describing: error)))
                return
            }
            if !archiveSamples.isEmpty, var archiveBuffer {
                for chunk in archiveBuffer.append(archiveSamples) {
                    for sink in archiveChunkSinks.values { sink.yield(chunk) }
                }
                self.archiveBuffer = archiveBuffer
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelAt >= configuration.levelInterval {
            lastLevelAt = now
            let level = AudioLevel.measure(samples)
            for sink in levelSinks.values { sink.yield(level) }
        }
    }

    private func emitLocked(_ event: AudioCaptureEvent) {
        for sink in eventSinks.values { sink.yield(event) }
    }

    // MARK: - Session

    #if os(iOS)
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: [])
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
    }

    /// A phone call or Siri suspends the engine; the chunk buffer keeps its pending
    /// samples, so resuming continues the same recording instead of corrupting it.
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        lock.withLock {
            switch type {
            case .began:
                guard state == .running else { return }
                engine.pause()
                state = .interrupted
                emitLocked(.interrupted)
            case .ended:
                guard state == .interrupted else { return }
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                guard shouldResume else {
                    emitLocked(.interruptionEnded(resumed: false))
                    return
                }
                do {
                    try activateSession()
                    try installTapLocked()
                    try engine.start()
                    state = .running
                    emitLocked(.interruptionEnded(resumed: true))
                } catch {
                    emitLocked(.failed(message: String(describing: error)))
                }
            @unknown default:
                return
            }
        }
    }

    /// AirPods in or out changes the input node's format, so the tap and the resampler
    /// are rebuilt. The chunk buffer is untouched, so chunk numbering stays continuous.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        lock.withLock {
            defer { emitLocked(.routeChanged(reason: Self.describe(reason), inputName: inputName)) }
            guard state == .running else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .override:
                do {
                    engine.stop()
                    try installTapLocked()
                    try engine.start()
                } catch {
                    state = .interrupted
                    emitLocked(.failed(message: String(describing: error)))
                }
            default:
                return
            }
        }
    }

    private static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "unhandled"
        }
    }
    #else
    private func activateSession() throws {}
    private func deactivateSession() {}
    private func observeSessionNotifications() {}
    #endif
}
