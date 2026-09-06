import Foundation
import Observation
import TranscriptCore

@MainActor
@Observable
final class RecorderModel {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused
        case stopping
    }

    /// Interruption / route notices (UI.md), kept as data rather than pre-formatted
    /// text so the displayed string re-localizes if the app language changes while a
    /// notice is showing.
    enum Notice: Equatable {
        case recovered(count: Int)
        case pausedByOtherApp
        case interrupted
        case inputSwitched(name: String)

        @MainActor
        var text: String {
            let localization = LocalizationManager.shared
            switch self {
            case .recovered(let count):
                return count == 1
                    ? localization.localized("Recovered 1 interrupted recording.")
                    : localization.localized("Recovered \(count) interrupted recordings.")
            case .pausedByOtherApp:
                return localization.localized("Paused by another app. Your recording is safe.")
            case .interrupted:
                return localization.localized("Interrupted. Tap resume to continue.")
            case .inputSwitched(let name):
                return localization.localized("Input switched to \(name).")
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var level: AudioLevel = .silence
    private(set) var elapsed: TimeInterval = 0
    private(set) var permission: MicrophonePermission.Status = .undetermined
    private(set) var noticeKind: Notice?
    var notice: String? { noticeKind?.text }
    var errorMessage: String?

    private let services: AppServices
    private let library: LibraryModel
    let transcription: TranscriptionModel
    private var levelTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let activityController: any RecordingActivityControlling
    private var lastActivitySecond = -1
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var didSalvage = false
    private var recordingMeetingId: String?
    private var stopInProgress = false
    private var captureFailure: String?
    private let processing: any RecordingTranscriptionControlling
    private let requestPermission: () async -> MicrophonePermission.Status

    init(
        services: AppServices,
        library: LibraryModel,
        activityController: any RecordingActivityControlling = RecordingActivityController(),
        transcription: TranscriptionModel? = nil,
        processing: (any RecordingTranscriptionControlling)? = nil,
        requestPermission: @escaping () async -> MicrophonePermission.Status = { await MicrophonePermission.request() }
    ) {
        self.services = services
        self.library = library
        self.transcription = transcription ?? TranscriptionModel(services: services)
        self.processing = processing ?? self.transcription
        self.requestPermission = requestPermission
        self.activityController = activityController
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }

    var isActive: Bool { phase == .recording || phase == .paused }
    var recordingSampleRate: Double { services.session.configuration.archiveQuality.archiveSampleRate }
    var recordingLanguageLabel: String {
        LocalizationManager.shared.resolvedLocale.localizedString(forIdentifier: services.recordingLocale.identifier)
            ?? services.recordingLocale.identifier
    }

    var stateLabel: String {
        let localization = LocalizationManager.shared
        switch phase {
        case .idle: return localization.localized("Ready")
        case .starting: return localization.localized("Starting")
        case .recording: return localization.localized("Recording")
        case .paused: return localization.localized("Paused")
        case .stopping: return localization.localized("Sealing")
        }
    }

    func onAppear() async {
        permission = MicrophonePermission.current
        transcription.refreshAvailability()
        observeStreams()
        guard !didSalvage else { return }
        didSalvage = true
        await activityController.cleanupOrphans()
        let salvaged = await services.salvageCrashedRecordings()
        if salvaged > 0 {
            noticeKind = .recovered(count: salvaged)
        }
        await library.reload()
    }

    func toggleRecording() async {
        switch phase {
        case .idle: await start()
        case .recording, .paused: await stop()
        case .starting, .stopping: break
        }
    }

    func togglePause() async {
        do {
            switch phase {
            case .recording:
                try await services.session.pause()
                accumulated += Date().timeIntervalSince(startedAt ?? Date())
                startedAt = nil
                phase = .paused
                level = .silence
            case .paused:
                try await services.session.resume()
                startedAt = Date()
                phase = .recording
            default:
                break
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func dismissNotice() {
        noticeKind = nil
    }

    // MARK: - Private

    private func start() async {
        guard phase == .idle else { return }
        phase = .starting
        defer {
            if phase == .idle { services.audioOwnership.releaseCapture() }
        }
        do {
            try services.audioOwnership.prepareForCapture()
            permission = await requestPermission()
            guard permission == .granted else {
                phase = .idle
                return
            }
            processing.refreshAvailability()
            try await processing.prepare()
            // Subscribed before capture starts, so no chunk is lost while the model
            // loads; the broadcast stream buffers until inference catches up.
            let chunks = services.session.chunks()
            let diarizationChunks = services.session.chunks()
            let meeting = try await services.session.start(title: Self.defaultTitle(at: Date()))
            try processing.start(
                meetingId: meeting.id,
                chunks: chunks,
                diarizationChunks: diarizationChunks
            )
            await recordingDidStart(meetingId: meeting.id)
        } catch {
            _ = try? await services.session.abort()
            await processing.discard()
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    func recordingDidStart(meetingId: String) async {
        accumulated = 0
        elapsed = 0
        lastActivitySecond = -1
        recordingMeetingId = meetingId
        captureFailure = nil
        startedAt = Date()
        phase = .recording
        startTicking()
        await activityController.start(meetingId: meetingId)
    }

    @discardableResult
    func requestStop() -> Task<Void, Never>? {
        guard isActive, let meetingId = recordingMeetingId else { return nil }
        return Task { @MainActor [weak self] in
            guard let self, recordingMeetingId == meetingId else { return }
            await stop()
        }
    }

    private func stop() async {
        guard !stopInProgress, isActive else { return }
        guard let meetingId = recordingMeetingId else {
            errorMessage = String(describing: AudioCaptureError.notRecording)
            return
        }
        stopInProgress = true
        defer { stopInProgress = false }
        phase = .stopping
        stopTicking()
        var pendingStop: RecordingSession.PendingStop?
        var stopFailure: (any Error)?
        let activityController = activityController
        do {
            pendingStop = try await services.session.drainCapture {
                await activityController.end(meetingId: meetingId)
            }
        } catch {
            stopFailure = error
            await activityController.end(meetingId: meetingId)
        }
        do {
            try await processing.finish()
        } catch {
            if stopFailure == nil { stopFailure = error }
        }
        if stopFailure == nil, let captureFailure {
            stopFailure = LiveRecordingDrainError(failures: [captureFailure])
        }
        if let pendingStop {
            do {
                _ = try await services.session.publish(
                    pendingStop,
                    as: stopFailure == nil ? .recorded : .failed
                )
            } catch {
                stopFailure = error
            }
        }
        if let stopFailure { errorMessage = stopFailure.localizedDescription }
        startedAt = nil
        recordingMeetingId = nil
        captureFailure = nil
        accumulated = 0
        elapsed = 0
        level = .silence
        phase = .idle
        services.audioOwnership.releaseCapture()
        await library.reload()
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, isActive else { return }
                if let startedAt {
                    elapsed = accumulated + Date().timeIntervalSince(startedAt)
                } else {
                    elapsed = accumulated
                }
                if RecordingActivityCommunication.consumeStopRequest(), isActive {
                    requestStop()
                    return
                }
                let activitySecond = Int(elapsed)
                if activitySecond != lastActivitySecond {
                    lastActivitySecond = activitySecond
                    guard let meetingId = recordingMeetingId else { return }
                    await activityController.update(
                        meetingId: meetingId,
                        elapsed: elapsed,
                        recentTranscriptLines: transcription.lines.prefix(3).map(\.text),
                        isPaused: phase == .paused
                    )
                }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func observeStreams() {
        guard levelTask == nil else { return }
        let levels = services.session.levels()
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self, isActive else { continue }
                self.level = level
            }
        }
        let events = services.session.events()
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handleCaptureEvent(event)
            }
        }
    }

    @discardableResult
    func handleCaptureEvent(_ event: AudioCaptureEvent) -> Task<Void, Never>? {
        switch event {
        case .interrupted:
            guard isActive else { return nil }
            phase = .paused
            level = .silence
            accumulated += Date().timeIntervalSince(startedAt ?? Date())
            startedAt = nil
            noticeKind = .pausedByOtherApp
        case .interruptionEnded(let resumed):
            guard isActive else { return nil }
            if resumed {
                startedAt = Date()
                phase = .recording
                noticeKind = nil
            } else {
                noticeKind = .interrupted
            }
        case .routeChanged(_, let inputName):
            guard isActive else { return nil }
            noticeKind = inputName.map { .inputSwitched(name: $0) }
        case .failed(let message):
            guard isActive || phase == .stopping else { return nil }
            errorMessage = message
            if captureFailure == nil { captureFailure = message }
            return requestStop()
        case .stopped:
            break
        case .started, .paused, .resumed:
            break
        }
        return nil
    }

    private static func defaultTitle(at date: Date) -> String {
        Format.date(date, dateStyle: .abbreviated, timeStyle: .shortened)
    }
}
