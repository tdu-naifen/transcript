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
            let locale = LocalizationManager.shared.resolvedLocale
            switch self {
            case .recovered(let count):
                return count == 1
                    ? String(localized: "Recovered 1 interrupted recording.", locale: locale)
                    : String(localized: "Recovered \(count) interrupted recordings.", locale: locale)
            case .pausedByOtherApp:
                return String(localized: "Paused by another app. Your recording is safe.", locale: locale)
            case .interrupted:
                return String(localized: "Interrupted. Tap resume to continue.", locale: locale)
            case .inputSwitched(let name):
                return String(localized: "Input switched to \(name).", locale: locale)
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
    private let activityController = RecordingActivityController()
    private var lastActivitySecond = -1
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var didSalvage = false

    init(services: AppServices, library: LibraryModel) {
        self.services = services
        self.library = library
        self.transcription = TranscriptionModel(services: services)
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }

    var isActive: Bool { phase == .recording || phase == .paused }

    var stateLabel: String {
        let locale = LocalizationManager.shared.resolvedLocale
        switch phase {
        case .idle: return String(localized: "Ready", locale: locale)
        case .starting: return String(localized: "Starting", locale: locale)
        case .recording: return String(localized: "Recording", locale: locale)
        case .paused: return String(localized: "Paused", locale: locale)
        case .stopping: return String(localized: "Sealing", locale: locale)
        }
    }

    func onAppear() async {
        permission = MicrophonePermission.current
        transcription.refreshAvailability()
        observeStreams()
        guard !didSalvage else { return }
        didSalvage = true
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
        permission = await MicrophonePermission.request()
        guard permission == .granted else { return }

        phase = .starting
        do {
            transcription.refreshAvailability()
            guard transcription.isAvailable else {
                throw TranscriptionModel.RecordingError.requiredModelsMissing
            }
            // Subscribed before capture starts, so no chunk is lost while the model
            // loads; the broadcast stream buffers until inference catches up.
            let chunks = services.session.chunks()
            let diarizationChunks = services.session.chunks()
            let meeting = try await services.session.start(title: Self.defaultTitle(at: Date()))
            try transcription.start(
                meetingId: meeting.id,
                chunks: chunks,
                diarizationChunks: diarizationChunks
            )
            accumulated = 0
            elapsed = 0
            lastActivitySecond = -1
            startedAt = Date()
            phase = .recording
            startTicking()
            await activityController.start(meetingId: meeting.id)
        } catch {
            _ = try? await services.session.abort()
            await transcription.discard()
            phase = .idle
            errorMessage = String(describing: error)
        }
    }

    private func stop() async {
        phase = .stopping
        stopTicking()
        var pendingStop: RecordingSession.PendingStop?
        var stopFailure: (any Error)?
        do {
            pendingStop = try await services.session.drainCapture()
        } catch {
            stopFailure = error
        }
        do {
            try await transcription.finish()
        } catch {
            if stopFailure == nil { stopFailure = error }
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
        if let stopFailure { errorMessage = String(describing: stopFailure) }
        await activityController.end()
        startedAt = nil
        accumulated = 0
        elapsed = 0
        level = .silence
        phase = .idle
        await library.reload()
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if let startedAt {
                    elapsed = accumulated + Date().timeIntervalSince(startedAt)
                } else {
                    elapsed = accumulated
                }
                if RecordingActivityCommunication.consumeStopRequest(), isActive {
                    await stop()
                    return
                }
                let activitySecond = Int(elapsed)
                if activitySecond != lastActivitySecond {
                    lastActivitySecond = activitySecond
                    await activityController.update(
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
                self?.level = level
            }
        }
        let events = services.session.events()
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: AudioCaptureEvent) {
        switch event {
        case .interrupted:
            phase = .paused
            level = .silence
            accumulated += Date().timeIntervalSince(startedAt ?? Date())
            startedAt = nil
            noticeKind = .pausedByOtherApp
        case .interruptionEnded(let resumed):
            if resumed {
                startedAt = Date()
                phase = .recording
                noticeKind = nil
            } else {
                noticeKind = .interrupted
            }
        case .routeChanged(_, let inputName):
            guard isActive else { return }
            noticeKind = inputName.map { .inputSwitched(name: $0) }
        case .failed(let message):
            errorMessage = message
        case .started, .paused, .resumed, .stopped:
            break
        }
    }

    private static func defaultTitle(at date: Date) -> String {
        Format.date(date, dateStyle: .abbreviated, timeStyle: .shortened)
    }
}
