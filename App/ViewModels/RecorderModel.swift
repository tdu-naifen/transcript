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

    private(set) var phase: Phase = .idle
    private(set) var level: AudioLevel = .silence
    private(set) var elapsed: TimeInterval = 0
    private(set) var permission: MicrophonePermission.Status = .undetermined
    /// Interruption / route messages, so the user knows why the meter went quiet.
    private(set) var notice: String?
    var errorMessage: String?

    private let services: AppServices
    private let library: LibraryModel
    let transcription: TranscriptionModel
    private var levelTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
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
        switch phase {
        case .idle: "Ready"
        case .starting: "Starting"
        case .recording: "Recording"
        case .paused: "Paused"
        case .stopping: "Sealing"
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
            notice = "Recovered \(salvaged) interrupted recording\(salvaged == 1 ? "" : "s")."
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
        notice = nil
    }

    // MARK: - Private

    private func start() async {
        permission = await MicrophonePermission.request()
        guard permission == .granted else { return }

        phase = .starting
        do {
            // Subscribed before capture starts, so no chunk is lost while the model
            // loads; the broadcast stream buffers until inference catches up.
            let chunks = services.session.chunks()
            let meeting = try await services.session.start(title: Self.defaultTitle())
            transcription.start(meetingId: meeting.id, chunks: chunks)
            accumulated = 0
            elapsed = 0
            startedAt = Date()
            phase = .recording
            startTicking()
        } catch {
            phase = .idle
            errorMessage = String(describing: error)
        }
    }

    private func stop() async {
        phase = .stopping
        stopTicking()
        do {
            _ = try await services.session.stop()
        } catch {
            // The meeting is still preserved, sealed into `failed` (PLAN §3.2.1).
            errorMessage = String(describing: error)
        }
        transcription.stop()
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
            notice = "Paused by another app. Your recording is safe."
        case .interruptionEnded(let resumed):
            if resumed {
                startedAt = Date()
                phase = .recording
                notice = nil
            } else {
                notice = "Interrupted. Tap resume to continue."
            }
        case .routeChanged(_, let inputName):
            guard isActive else { return }
            notice = inputName.map { "Input switched to \($0)." }
        case .failed(let message):
            errorMessage = message
        case .started, .paused, .resumed, .stopped:
            break
        }
    }

    /// The subtitle already shows the date (UI.md row layout), so the default title
    /// must not restate it — otherwise every unnamed recording shows the same
    /// timestamp twice.
    private static func defaultTitle() -> String {
        "未命名录音"
    }
}
