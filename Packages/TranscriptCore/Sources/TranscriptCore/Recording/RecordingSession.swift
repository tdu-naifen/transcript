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

    public struct PendingStop: Sendable, Hashable {
        public let meetingId: String
        private let generation = UUID()

        init(meetingId: String) {
            self.meetingId = meetingId
        }
    }

    private struct Pending {
        let token: PendingStop
        let durationMs: Int
        let audio: SealedAudio
        let state: MeetingState
    }

    public nonisolated let configuration: AudioCaptureConfiguration

    private let meetings: MeetingRepository
    private let store: AudioFileStore
    private let deviceId: String
    private let engine: any AudioCaptureControlling
    private var active: Active?
    private var pending: Pending?
    private var published: Set<PendingStop> = []
    private var phase: Phase = .idle
    private var drainInProgress = false

    public init(
        database: AppDatabase,
        deviceId: String,
        store: AudioFileStore,
        configuration: AudioCaptureConfiguration = AudioCaptureConfiguration(),
        captureEngine: (any AudioCaptureControlling)? = nil
    ) {
        self.meetings = MeetingRepository(database)
        self.store = store
        self.deviceId = deviceId
        self.configuration = configuration
        self.engine = captureEngine ?? AudioCaptureEngine(configuration: configuration)
    }

    /// Where a future ASR consumer plugs in: its own broadcast copy of the chunk stream,
    /// independent of the copy that feeds the file writer.
    public nonisolated func chunks() -> AsyncStream<AudioChunk> { engine.chunks() }

    public nonisolated func levels() -> AsyncStream<AudioLevel> { engine.levels() }

    public nonisolated func events() -> AsyncStream<AudioCaptureEvent> { engine.events() }

    public var currentPhase: Phase { phase }

    private var sealingMeetingId: String?
    public var activeMeetingId: String? { active?.meetingId ?? pending?.token.meetingId ?? sealingMeetingId }

    public func start(title: String, now: Date = Date()) async throws -> Meeting {
        guard active == nil, pending == nil, !drainInProgress, sealingMeetingId == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        let meeting = Meeting(
            title: title,
            startedAt: now,
            state: .recording,
            createdAt: now,
            updatedAt: now,
            originDeviceId: deviceId
        )
        sealingMeetingId = meeting.id
        defer { sealingMeetingId = nil }
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
        let token = try await drainCapture(now: now)
        return try await publish(token, as: .recorded, now: now)
    }

    /// Closes capture and durably saves the archive before optional processing drains.
    /// On success the database contains its actual captured duration, filename, hash,
    /// byte count, and archive state. `.recorded` does not promise a final transcript.
    /// `activeMeetingId` remains reserved until `publish`, preventing a new capture,
    /// deletion, or reprocessing from racing the old downstream consumers.
    /// A database failure retains the pending seal: calling again retries persistence,
    /// never the encoder. `publish` releases the downstream-processing fence.
    public func drainCapture(
        now: Date = Date(),
        archiveState: MeetingState = .recorded,
        onCaptureStopped: @escaping @Sendable () async -> Void = {}
    ) async throws -> PendingStop {
        guard !drainInProgress else { throw AudioCaptureError.alreadyRecording }
        guard archiveState == .recorded || archiveState == .failed else {
            throw IllegalMeetingStateTransition(from: .recording, to: archiveState)
        }
        drainInProgress = true
        defer { drainInProgress = false; sealingMeetingId = nil }
        if let pending {
            _ = try await persist(pending, now: now)
            return pending.token
        }
        guard let active else { throw AudioCaptureError.notRecording }
        sealingMeetingId = active.meetingId
        self.active = nil
        phase = .idle

        engine.stop()
        let captureStopped = Task { await onCaptureStopped() }
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

        let audio: SealedAudio
        do {
            audio = try await active.writer.finish()
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
        let token = PendingStop(meetingId: active.meetingId)
        guard durationMs > 0 else {
            _ = try await sealFailure(
                meetingId: active.meetingId, fileName: audio.fileName, durationMs: 0, now: now
            )
            throw AudioCaptureError.writerFailed("No audio samples were captured.")
        }
        let pending = Pending(token: token, durationMs: durationMs, audio: audio, state: archiveState)
        self.pending = pending
        _ = try await persist(pending, now: now)
        await captureStopped.value
        return token
    }

    /// Acknowledges downstream completion. Processing failures cannot downgrade a
    /// successfully saved archive. Repeated acknowledgments never mutate another session
    /// or resurrect a deleted meeting.
    @discardableResult
    public func publish(
        _ token: PendingStop,
        as state: MeetingState,
        now: Date = Date()
    ) async throws -> Meeting {
        guard state == .recorded || state == .failed else {
            throw IllegalMeetingStateTransition(from: .recording, to: state)
        }
        if published.contains(token) {
            guard let meeting = try await meetings.fetch(id: token.meetingId) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: token.meetingId)
            }
            return meeting
        }
        guard let pending, pending.token == token else { throw AudioCaptureError.notRecording }
        let meeting = try await persist(pending, now: now)
        published.insert(token)
        if self.pending?.token == token { self.pending = nil }
        return meeting
    }

    private func persist(_ pending: Pending, now: Date) async throws -> Meeting {
        try await meetings.sealRecording(
            id: pending.token.meetingId,
            to: pending.state,
            durationMs: pending.durationMs,
            audio: pending.audio,
            deviceId: deviceId,
            now: now
        )
    }

    /// Gives up on the current recording but keeps the partial result, so it can be
    /// salvaged later with `failed → recorded`.
    @discardableResult
    public func abort(now: Date = Date()) async throws -> Meeting? {
        guard let active else { return nil }
        sealingMeetingId = active.meetingId
        defer { sealingMeetingId = nil }
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
