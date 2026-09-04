import AVFoundation
import Foundation

/// One recording, from `Meeting` creation to a sealed Layer A row.
///
/// Owns the capture engine and the file writer, and is the only thing that seals a
/// meeting, so `durationMs` / `audioFileName` / `audioSHA256` / `audioByteCount` can
/// never drift apart (PLAN §9.4.1).
public actor RecordingSession {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case recording
        case paused
    }

    private struct Active {
        let meetingId: String
        let writer: AudioFileWriter
        let task: Task<(frames: Int, failure: String?), Never>
    }

    public nonisolated let configuration: AudioCaptureConfiguration

    private let meetings: MeetingRepository
    private let store: AudioFileStore
    private let deviceId: String
    private let engine: AudioCaptureEngine
    private var active: Active?
    private var phase: Phase = .idle

    public init(
        database: AppDatabase,
        deviceId: String,
        store: AudioFileStore,
        configuration: AudioCaptureConfiguration = AudioCaptureConfiguration()
    ) {
        self.meetings = MeetingRepository(database)
        self.store = store
        self.deviceId = deviceId
        self.configuration = configuration
        self.engine = AudioCaptureEngine(configuration: configuration)
    }

    /// Where a future ASR consumer plugs in: its own broadcast copy of the chunk stream,
    /// independent of the copy that feeds the file writer.
    public nonisolated func chunks() -> AsyncStream<AudioChunk> { engine.chunks() }

    public nonisolated func levels() -> AsyncStream<AudioLevel> { engine.levels() }

    public nonisolated func events() -> AsyncStream<AudioCaptureEvent> { engine.events() }

    public var currentPhase: Phase { phase }

    public var activeMeetingId: String? { active?.meetingId }

    public func start(title: String, now: Date = Date()) async throws -> Meeting {
        guard active == nil else { throw AudioCaptureError.alreadyRecording }

        let meeting = Meeting(
            title: title,
            startedAt: now,
            state: .recording,
            createdAt: now,
            updatedAt: now,
            originDeviceId: deviceId
        )
        try await meetings.insert(meeting)

        let url = try store.url(for: meeting.id)
        let writer = try AudioFileWriter(
            url: url,
            sampleRate: configuration.sampleRate,
            bitRate: configuration.audioBitRate,
            segmentSeconds: configuration.segmentSeconds
        )
        try writer.start()

        // Subscribe before the engine starts so no chunk can be missed.
        let stream = engine.chunks()
        let task = Task<(frames: Int, failure: String?), Never> {
            var frames = 0
            var failure: String?
            for await chunk in stream {
                if failure == nil {
                    do {
                        try await writer.append(chunk)
                        frames += chunk.frameCount
                    } catch {
                        failure = String(describing: error)
                    }
                }
                if chunk.isFinal { break }
            }
            return (frames, failure)
        }

        do {
            try engine.start()
        } catch {
            task.cancel()
            writer.abandon()
            _ = try? await sealFailure(meetingId: meeting.id, fileName: url.lastPathComponent, durationMs: 0, now: now)
            throw error
        }

        active = Active(meetingId: meeting.id, writer: writer, task: task)
        phase = .recording
        return meeting
    }

    public func pause() throws {
        guard active != nil, phase == .recording else { throw AudioCaptureError.notRecording }
        try engine.pause()
        phase = .paused
    }

    public func resume() throws {
        guard active != nil, phase == .paused else { throw AudioCaptureError.notRecording }
        try engine.resume()
        phase = .recording
    }

    /// Stops capture and seals the meeting into `recorded` atomically.
    ///
    /// If anything went wrong while writing, the meeting is sealed into `failed`
    /// instead — with whatever audio and duration were captured — and the error is
    /// rethrown. Nothing is discarded (PLAN §3.2.1).
    @discardableResult
    public func stop(now: Date = Date()) async throws -> Meeting {
        guard let active else { throw AudioCaptureError.notRecording }
        self.active = nil
        phase = .idle

        engine.stop()
        let outcome = await active.task.value
        let durationMs = Self.durationMs(frames: outcome.frames, sampleRate: configuration.sampleRate)

        if let failure = outcome.failure {
            active.writer.abandon()
            try await sealFailure(
                meetingId: active.meetingId,
                fileName: active.writer.fileName,
                durationMs: durationMs,
                now: now
            )
            throw AudioCaptureError.writerFailed(failure)
        }

        do {
            let audio = try await active.writer.finish()
            return try await meetings.sealRecording(
                id: active.meetingId,
                to: .recorded,
                durationMs: durationMs,
                audio: audio,
                deviceId: deviceId,
                now: now
            )
        } catch {
            active.writer.abandon()
            try await sealFailure(
                meetingId: active.meetingId,
                fileName: active.writer.fileName,
                durationMs: durationMs,
                now: now
            )
            throw error
        }
    }

    /// Gives up on the current recording but keeps the partial result, so it can be
    /// salvaged later with `failed → recorded`.
    @discardableResult
    public func abort(now: Date = Date()) async throws -> Meeting? {
        guard let active else { return nil }
        self.active = nil
        phase = .idle

        engine.stop()
        let outcome = await active.task.value
        active.writer.abandon()
        return try await sealFailure(
            meetingId: active.meetingId,
            fileName: active.writer.fileName,
            durationMs: Self.durationMs(frames: outcome.frames, sampleRate: configuration.sampleRate),
            now: now
        )
    }

    public nonisolated func invalidate() {
        engine.invalidate()
    }

    @discardableResult
    private func sealFailure(
        meetingId: String,
        fileName: String,
        durationMs: Int,
        now: Date
    ) async throws -> Meeting {
        var audio: SealedAudio?
        // The live hash never completed, so the partial file is hashed once here.
        if let url = try? store.url(forFileName: fileName),
           FileManager.default.fileExists(atPath: url.path),
           let hashed = try? IncrementalSHA256.hashFile(at: url),
           hashed.byteCount > 0 {
            audio = SealedAudio(fileName: fileName, sha256: hashed.sha256, byteCount: hashed.byteCount)
        }
        return try await meetings.sealRecording(
            id: meetingId,
            to: .failed,
            durationMs: durationMs,
            audio: audio,
            deviceId: deviceId,
            now: now
        )
    }

    static func durationMs(frames: Int, sampleRate: Double) -> Int {
        guard frames > 0, sampleRate > 0 else { return 0 }
        return Int((Double(frames) / sampleRate * 1000).rounded())
    }
}
