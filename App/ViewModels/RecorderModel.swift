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

    /// Interruption / route notices, kept as data rather than pre-formatted
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
    private(set) var audioArchiveSaved = false
    private(set) var lastArchivedMeeting: Meeting?
    var canStartRecording: Bool { phase == .idle && !stopInProgress }
    private(set) var level: AudioLevel = .silence
    private(set) var elapsed: TimeInterval = 0
    private(set) var permission: MicrophonePermission.Status = .undetermined
    private(set) var noticeKind: Notice?
    var notice: String? { noticeKind?.text }
    var errorMessage: String?

    private let services: AppServices
    private let library: LibraryModel
    private(set) var transcription: TranscriptionModel
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
    private var sceneIsActive = true
    private var processing: any RecordingTranscriptionControlling
    private let makeTranscription: () -> TranscriptionModel
    private let makeProcessing: ((TranscriptionModel) -> any RecordingTranscriptionControlling)?
    private var inputs: [BoundedRecordingInput] = []
    private let requestPermission: () async -> MicrophonePermission.Status
    private let consumeStopRequest: (String) -> Bool

    init(
        services: AppServices,
        library: LibraryModel,
        activityController: any RecordingActivityControlling = RecordingActivityController(),
        transcription: TranscriptionModel? = nil,
        processing: (any RecordingTranscriptionControlling)? = nil,
        makeTranscription: (() -> TranscriptionModel)? = nil,
        makeProcessing: ((TranscriptionModel) -> any RecordingTranscriptionControlling)? = nil,
        requestPermission: @escaping () async -> MicrophonePermission.Status = { await MicrophonePermission.request() },
        consumeStopRequest: @escaping (String) -> Bool = { RecordingActivityCommunication.consumeStopRequest(for: $0) }
    ) {
        self.services = services
        self.library = library
        let initialTranscription = transcription ?? TranscriptionModel(services: services)
        self.transcription = initialTranscription
        self.processing = processing ?? initialTranscription
        self.makeTranscription = makeTranscription ?? { TranscriptionModel(services: services) }
        self.makeProcessing = makeProcessing
        self.requestPermission = requestPermission
        self.consumeStopRequest = consumeStopRequest
        self.activityController = activityController
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }

    var isActive: Bool { phase == .recording || phase == .paused }
    var recordingSampleRate: Double { services.session.configuration.archiveQuality.archiveSampleRate }
    var recordingLanguageLabel: String {
        guard let locale = transcription.effectiveLocale else {
            return RecordingLanguageText.text("Audio only")
        }
        return LocalizationManager.shared.resolvedLocale.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    func selectRecordingLanguage(_ identifier: String) {
        guard phase == .recording else { return }
        transcription.requestLanguage(identifier == "auto" ? Locale.current : Locale(identifier: identifier))
    }

    func sceneActivityChanged(isActive: Bool) {
        sceneIsActive = isActive
        services.recordingFinalization.setActive(isActive)
        transcription.setLanguageSwitchingAllowed(isActive && phase == .recording)
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
        if let recoveryError = services.recordingRecoveryError {
            errorMessage = recoveryError
            didSalvage = false
        }
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
                transcription.setLanguageSwitchingAllowed(false)
                try await services.session.pause()
                accumulated += Date().timeIntervalSince(startedAt ?? Date())
                startedAt = nil
                phase = .paused
                level = .silence
            case .paused:
                try await services.session.resume()
                startedAt = Date()
                phase = .recording
                transcription.setLanguageSwitchingAllowed(sceneIsActive)
            default:
                break
            }
        } catch {
            transcription.setLanguageSwitchingAllowed(sceneIsActive && phase == .recording)
            errorMessage = String(describing: error)
        }
    }

    func dismissNotice() {
        noticeKind = nil
    }

    // MARK: - Private

    private func start() async {
        guard canStartRecording else { return }
        phase = .starting
        errorMessage = nil
        defer {
            if phase == .idle { services.audioOwnership.releaseCapture() }
        }
        do {
            // A failed database write must be retried before a new capture replaces
            // its pending archive. This does not restart an already drained encoder.
            if await services.session.activeMeetingId != nil {
                let pending = try await services.session.drainCapture()
                try await services.recordingFinalization.adoptArchive(pending)
                lastArchivedMeeting = try? await MeetingRepository(services.database).fetch(id: pending.meetingId)
            }
            try services.audioOwnership.prepareForCapture()
            permission = await requestPermission()
            guard permission == .granted else {
                phase = .idle
                return
            }
            processing.refreshAvailability()
            let recordingLocale = services.recordingLocale
            try await processing.prepare()
            let model = transcription
            let speechInput = BoundedRecordingInput(source: services.session.chunks()) { model.markInputIncomplete() }
            let speakerInput = BoundedRecordingInput(source: services.session.chunks()) { model.markSpeakerInputIncomplete() }
            inputs = [speechInput, speakerInput]
            let meeting = try await services.session.start(
                title: Self.defaultTitle(at: Date()), localeIdentifier: recordingLocale.identifier
            )
            try processing.start(
                meetingId: meeting.id,
                chunks: speechInput.stream,
                diarizationChunks: speakerInput.stream
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
        audioArchiveSaved = false
        startedAt = Date()
        phase = .recording
        transcription.setLanguageSwitchingAllowed(sceneIsActive)
        startTicking()
        await activityController.start(meetingId: meetingId)
    }

    @discardableResult
    func requestStop() -> Task<Void, Never>? {
        guard isActive, let meetingId = recordingMeetingId else { return nil }
        transcription.setLanguageSwitchingAllowed(false)
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
        defer {
            stopInProgress = false
        }
        phase = .stopping
        transcription.setLanguageSwitchingAllowed(false)
        stopTicking()
        var pendingStop: RecordingSession.PendingStop?
        var stopFailure: (any Error)?
        let oldProcessor = processing
        let oldCaptureFailure = captureFailure
        let activityController = activityController
        do {
            pendingStop = try await services.session.drainCapture(
                archiveState: captureFailure == nil ? .recorded : .failed
            ) {
                await activityController.end(meetingId: meetingId)
            }
        } catch {
            stopFailure = error
            await activityController.end(meetingId: meetingId)
        }
        if let stopFailure {
            RecordingDiagnostics.log(stopFailure)
            errorMessage = stopFailure.localizedDescription
        }
        // Transfer the old processor and token before exposing an idle recorder.
        // No finalization task captures this mutable recorder.
        if pendingStop != nil {
            lastArchivedMeeting = try? await MeetingRepository(services.database).fetch(id: meetingId)
        }
        audioArchiveSaved = pendingStop != nil
        startedAt = nil
        level = .silence
        services.audioOwnership.releaseCapture()
        await services.recordingFinalization.enqueue(
            token: pendingStop, meetingId: meetingId, processor: oldProcessor,
            services: services, library: library,
            captureFailure: stopFailure?.localizedDescription ?? oldCaptureFailure
        )
        transcription = makeTranscription()
        processing = makeProcessing?(transcription) ?? transcription
        inputs.removeAll()
        startedAt = nil
        recordingMeetingId = nil
        captureFailure = nil
        accumulated = 0
        elapsed = 0
        level = .silence
        services.audioOwnership.releaseCapture()
        await library.reload()
        phase = .idle
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
                if consumeActivityStopRequest() != nil { return }
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

    @discardableResult
    func consumeActivityStopRequest() -> Task<Void, Never>? {
        guard isActive, let id = recordingMeetingId, consumeStopRequest(id) else { return nil }
        return requestStop()
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
            transcription.setLanguageSwitchingAllowed(false)
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
                transcription.setLanguageSwitchingAllowed(sceneIsActive)
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
