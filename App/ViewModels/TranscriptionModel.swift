import Foundation
import struct FluidAudio.DiarizerSegment
import Observation
import TranscriptCore

/// Live transcript state for the record screen.
///
/// Apple's speech analyzer runs off the main actor and uses system-managed assets.
@MainActor
@Observable
final class TranscriptionModel {
    enum RecordingError: LocalizedError {
        case processingNotRunning
        case noTranscriptProduced

        var errorDescription: String? {
            switch self {
            case .processingNotRunning: String(localized: "Transcription is not running. Your audio is preserved.")
            case .noTranscriptProduced: String(localized: "No transcript was produced. Your audio is preserved.")
            }
        }
    }

    enum Status: Equatable {
        case modelMissing
        case idle
        case preparing
        case running
        case failed(String)
    }

    /// Newest line first, matching the record screen's layout.
    private(set) var lines: [ASRSegment] = []
    private(set) var status: Status = .idle
    private(set) var computeUnit: String?
    private(set) var detectedLanguage: String?
    private(set) var diarizationSegments: [DiarizerSegment] = []
    private(set) var speakersByIndex: [Int: Speaker] = [:]
    private(set) var displayedMeetingID: String?
    private(set) var speakerProjection = SpeakerProjection.empty
    private(set) var speakerProjectionObservedAt: TimeInterval = 0
    private var diarizationIsRunning = false
    private(set) var effectiveLocale: Locale?
    private(set) var pendingLocale: Locale?
    private(set) var languageSwitchFailure: RecordingLanguageIssue?
    private(set) var speakerWarning: String?
    private(set) var languageReadyForBoundary = false
    var languageProgress: Double? { pendingLocale.flatMap { resources.fractionCompleted(for: $0) } }

    private let services: AppServices
    private let resources: AppleSpeechResources
    private let analyzerSlots = RecordingAnalyzerSlots.shared
    private var preparedSlot: UUID?
    private var transcriber: (any AppleTranscribing)?
    private let makeTranscriber: () -> any AppleTranscribing
    private let preparationTimeout: Duration
    private var audioOnly = false
    private var resourceRecoveryLocale: Locale?
    private var liveSpeakers: LiveDynamicSpeakers?
    private let makeLiveSpeakers: (String) -> LiveDynamicSpeakers?
    private var liveSpeakerEvents: Task<Void, Never>?
    @ObservationIgnored private var speakerObservationTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private var currentMeetingId: String?
    private var diarizationTimeline = DiarizationTimelineAccumulator()
    private var processingFailure: String?
    private var incomplete = false
    private var routingTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private var switchGeneration = UUID()
    private var activeRunID: UUID?
    private var acceptsSwitches = false
    private var activeBoundary: RecordingLanguageBoundary?
    private var routedLocale: Locale?
    private var replacement: (engine: any AppleTranscribing, locale: Locale, slot: UUID)?
    private var runs: [SpeechRun] = []
    private struct SpeechRun {
        let id: UUID
        let engine: any AppleTranscribing
        let channel: RecordingChunkChannel
        let events: Task<Void, Never>
    }
    private var injectedFinishOperations: (
        asr: @Sendable () async throws -> Void,
        diarization: @Sendable () async throws -> Void
    )?

    init(
        services: AppServices, resources: AppleSpeechResources? = nil,
        preparationTimeout: Duration = .seconds(3),
        makeTranscriber: @escaping () -> any AppleTranscribing = { AppleLiveTranscriber() },
        makeLiveSpeakers: ((String) -> LiveDynamicSpeakers?)? = nil
    ) {
        self.services = services
        // Future-default setup must not cancel a language change in the active meeting.
        self.resources = resources ?? AppleSpeechResources()
        self.makeTranscriber = makeTranscriber
        self.makeLiveSpeakers = makeLiveSpeakers ?? { services.makeLiveSpeakers(meetingID: $0) }
        self.preparationTimeout = preparationTimeout
        self.injectedFinishOperations = nil
        status = .idle
    }

    init(
        services: AppServices,
        meetingId: String,
        asrFinish: @escaping @Sendable () async throws -> Void,
        diarizationFinish: @escaping @Sendable () async throws -> Void
    ) {
        self.services = services
        self.resources = services.speechResources
        self.makeTranscriber = { AppleLiveTranscriber() }
        self.makeLiveSpeakers = { services.makeLiveSpeakers(meetingID: $0) }
        self.preparationTimeout = .seconds(3)
        self.injectedFinishOperations = (asr: asrFinish, diarization: diarizationFinish)
        self.currentMeetingId = meetingId
        self.displayedMeetingID = meetingId
        status = .idle
        startSpeakerObservation(meetingID: meetingId)
    }

    deinit { speakerObservationTask?.cancel() }

    var isAvailable: Bool { status != .modelMissing }
    var needsForegroundFinalization: Bool {
        !runs.isEmpty || injectedFinishOperations != nil
    }
    var processingIssue: String? {
        incomplete || audioOnly ? RecordingSpeechUnavailable().localizedDescription : nil
    }

    func refreshAvailability() {
        guard status == .idle || status == .modelMissing else { return }
        status = .idle
    }

    func prepare() async throws {
        status = .preparing
        audioOnly = false
        resourceRecoveryLocale = nil
        effectiveLocale = nil
        speakerWarning = nil
        let locale = services.recordingLocale
        incomplete = false
        let availableSlot = services.recordingFinalization.isSaturated ? nil : await analyzerSlots.acquireIfAvailable()
        guard let slot = availableSlot else {
            transcriber = nil
            audioOnly = true
            incomplete = true
            status = .failed(RecordingResourcesBusy().localizedDescription)
            return
        }
        let transcriber = makeTranscriber()
        do {
            try await RecordingSpeechPreparation.prepare(
                transcriber, locale: locale, slot: slot, slots: analyzerSlots, timeout: preparationTimeout
            )
            self.transcriber = transcriber
            preparedSlot = slot
            effectiveLocale = locale
        } catch is CancellationError {
            status = .idle
            throw CancellationError()
        } catch {
            if case AppleLiveTranscriber.Failure.resourcesNotReady = error {
                resourceRecoveryLocale = locale
                resources.prepare(locale: locale)
            }
            // Transcription availability must not prevent saving microphone audio.
            self.transcriber = nil
            audioOnly = true
            incomplete = true
            RecordingDiagnostics.log(error)
            status = .failed(error is RecordingResourcesBusy
                ? error.localizedDescription
                : (error as? AppleLiveTranscriber.Failure)?.localizedDescription ?? RecordingLanguageText.speechFailure)
        }

    }

    func markInputIncomplete() {
        incomplete = true
    }

    func markSpeakerInputIncomplete() {
        speakerWarning = RecordingLanguageText.speakerFailure
    }

    /// Subscribe before capture starts. Bounded inputs report any inference gaps;
    /// the independent audio archive remains available for explicit retry.
    func start(
        meetingId: String,
        chunks: AsyncStream<AudioChunk>,
        diarizationChunks: AsyncStream<AudioChunk>
    ) throws {
        lines.removeAll()
        diarizationSegments.removeAll()
        diarizationTimeline = DiarizationTimelineAccumulator()
        speakersByIndex.removeAll()
        speakerProjection = .empty
        displayedMeetingID = meetingId
        diarizationIsRunning = false
        speakerWarning = nil
        processingFailure = nil
        detectedLanguage = nil
        currentMeetingId = meetingId
        startSpeakerObservation(meetingID: meetingId)
        routedLocale = nil
        acceptsSwitches = true
        if let transcriber, let effectiveLocale, let slot = preparedSlot {
            preparedSlot = nil
            activate(transcriber, locale: effectiveLocale, meetingID: meetingId, slot: slot)
        } else if !audioOnly {
            throw RecordingError.processingNotRunning
        }
        routingTask = Task { [weak self] in
            for await chunk in chunks {
                guard !Task.isCancelled, let self else { break }
                if acceptsSwitches, !chunk.samples.isEmpty, let replacement {
                    self.replacement = nil
                    let generation = switchGeneration
                    let boundary = RecordingLanguageBoundary()
                    activeBoundary = boundary
                    do {
                        try await RecordingProcessingRepository(services.database).commitLanguageBoundary(
                            meetingId: meetingId, previousLocale: routedLocale?.identifier,
                            newLocale: replacement.locale.identifier, boundary: boundary
                        )
                        try Task.checkCancellation()
                        let old = runs.last
                        activate(replacement.engine, locale: replacement.locale, meetingID: meetingId, slot: replacement.slot)
                        if generation == switchGeneration {
                            pendingLocale = nil
                            languageReadyForBoundary = false
                            languageSwitchFailure = nil
                        }
                        if let old { await old.channel.finish() }
                    } catch {
                        let slots = analyzerSlots
                        Task {
                            await replacement.engine.cancelAndWait()
                            await slots.release(replacement.slot)
                        }
                        if !(error is CancellationError) {
                            incomplete = true
                            RecordingDiagnostics.log(error)
                            if generation == switchGeneration { languageSwitchFailure = RecordingLanguageIssue(error) }
                        }
                    }
                    if activeBoundary === boundary { activeBoundary = nil }
                }
                if Task.isCancelled { break }
                if let run = runs.last {
                    if !chunk.samples.isEmpty { routedLocale = effectiveLocale }
                    await run.channel.send(chunk)
                }
            }
            if let run = self?.runs.last { await run.channel.finish() }
        }

        // No fixed local model slot is ever a persisted speaker identity.
        let live = makeLiveSpeakers(meetingId)
        liveSpeakers = live
        if let live {
            liveSpeakerEvents = Task { [weak self] in
                for await event in live.events {
                    guard !Task.isCancelled else { break }
                    await self?.apply(event, meetingId: meetingId)
                }
            }
        }
        diarizationTask = Task {
            for await chunk in diarizationChunks {
                guard !Task.isCancelled else { break }
                await live?.ingest(chunk)
            }
        }
        if audioOnly, let locale = resourceRecoveryLocale {
            resourceRecoveryLocale = nil
            switch resources.state(for: locale) {
            case .preparing, .ready:
                requestLanguage(locale)
            case .failed(let issue):
                pendingLocale = locale
                languageSwitchFailure = issue
            case .idle:
                break
            }
        }
    }

    func requestLanguage(_ locale: Locale) {
        guard acceptsSwitches, let meetingID = currentMeetingId else { return }
        cancelLanguageSwitch()
        pendingLocale = locale
        let token = switchGeneration
        switchTask = Task { [weak self] in
            guard let self else { return }
            var candidate: (any AppleTranscribing)?
            var candidateSlot: UUID?
            do {
                try await resources.prepareAndWait(locale: locale)
                try Task.checkCancellation()
                guard switchGeneration == token, acceptsSwitches, currentMeetingId == meetingID else { return }
                let slot = try await analyzerSlots.acquire()
                candidateSlot = slot
                try Task.checkCancellation()
                guard switchGeneration == token, acceptsSwitches, currentMeetingId == meetingID else { throw CancellationError() }
                let engine = makeTranscriber()
                candidate = engine
                try await engine.prepare(locale: locale)
                try Task.checkCancellation()
                guard switchGeneration == token, acceptsSwitches, currentMeetingId == meetingID else {
                    throw CancellationError()
                }
                // The router commits this only at the next chunk boundary.
                replacement = (engine, locale, slot)
                candidateSlot = nil
                languageReadyForBoundary = true
            } catch {
                if let candidate { await candidate.cancelAndWait() }
                if let candidateSlot { await analyzerSlots.release(candidateSlot) }
                guard switchGeneration == token else { return }
                RecordingDiagnostics.log(error)
                languageSwitchFailure = RecordingLanguageIssue(error, preserveSpeechReason: true)
            }
        }
    }

    func retryLanguageSwitch() {
        if let pendingLocale { requestLanguage(pendingLocale) }
    }

    func cancelLanguageSwitch() {
        activeBoundary?.cancel()
        switchGeneration = UUID()
        switchTask?.cancel()
        switchTask = nil
        if let pendingLocale { resources.cancel(locale: pendingLocale) }
        pendingLocale = nil
        languageSwitchFailure = nil
        languageReadyForBoundary = false
        if let replacement {
            self.replacement = nil
            let slots = analyzerSlots
            Task {
                await replacement.engine.cancelAndWait()
                await slots.release(replacement.slot)
            }
        }
    }

    func setLanguageSwitchingAllowed(_ allowed: Bool) {
        acceptsSwitches = allowed && currentMeetingId != nil
        liveSpeakers?.setActive(allowed && currentMeetingId != nil)
        if !allowed { cancelLanguageSwitch() }
    }

    private func activate(_ engine: any AppleTranscribing, locale: Locale, meetingID: String, slot: UUID) {
        let id = UUID()
        let channel = RecordingChunkChannel()
        activeRunID = id
        effectiveLocale = locale
        detectedLanguage = locale.identifier
        transcriber = engine
        audioOnly = false
        status = .preparing
        let store = AppleTranscriptStore(
            repository: UtteranceRepository(services.database), meetingID: meetingID, deviceID: services.deviceId
        )
        let slots = analyzerSlots
        let events = Task { [weak self] in
            let events = await engine.events()
            await engine.run(chunks: channel.stream, meetingID: meetingID, services: store)
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.apply(event, runID: id)
            }
            await channel.finish()
            // Drain both the native results collector and our event consumer
            // before another replacement may claim this analyzer slot.
            _ = try? await engine.finishAndWait()
            await slots.release(slot)
        }
        runs.append(SpeechRun(id: id, engine: engine, channel: channel, events: events))
    }

    func finish() async throws {
        setLanguageSwitchingAllowed(false)
        liveSpeakers?.close()
        diarizationTask?.cancel()
        liveSpeakerEvents?.cancel()
        await routingTask?.value
        routingTask = nil
        var failure: (any Error)?
        let finishOperations: (
            asr: @Sendable () async throws -> Void,
            diarization: @Sendable () async throws -> Void
        )
        if audioOnly {
            finishOperations = (asr: {}, diarization: {})
        } else if !runs.isEmpty {
            let engines = runs.map(\.engine)
            finishOperations = (
                asr: {
                    var failure: (any Error)?
                    for engine in engines {
                        do { try await engine.finishAndWait() }
                        catch { if failure == nil || failure is RecordingSpeechUnavailable { failure = error } }
                    }
                    if let failure { throw failure }
                },
                diarization: {}
            )
        } else if let injectedFinishOperations {
            finishOperations = injectedFinishOperations
        } else {
            throw RecordingError.processingNotRunning
        }
        do {
            try await finishOperations.asr()
        } catch {
            failure = error
        }
        do { try await finishOperations.diarization() }
        catch { errorMessageForDiarization(String(describing: error)) }
        for run in runs { await run.events.value }
        await eventTask?.value
        await diarizationTask?.value
        await liveSpeakers?.reconcileAcceptedEvidence()
        if (failure == nil || failure is RecordingSpeechUnavailable), let processingFailure {
            failure = LiveRecordingDrainError(failures: [processingFailure])
        }
        if failure == nil, incomplete || audioOnly {
            failure = RecordingSpeechUnavailable()
        }
        do {
            try await reconcileSpeakerAssignments()
            if injectedFinishOperations != nil { try await requireTranscriptProduced() }
        } catch {
            if failure == nil || failure is RecordingSpeechUnavailable { failure = error }
            RecordingDiagnostics.log(error)
        }
        eventTask = nil
        diarizationTask = nil
        self.transcriber = nil
        liveSpeakers = nil
        liveSpeakerEvents = nil
        diarizationIsRunning = false
        injectedFinishOperations = nil
        currentMeetingId = nil
        audioOnly = false
        runs.removeAll()
        activeRunID = nil
        if let failure {
            RecordingDiagnostics.log(failure)
            status = .failed(RecordingLanguageText.speechFailure)
            throw failure
        }
        status = .idle
    }

    func discard() async {
        speakerObservationTask?.cancel()
        speakerObservationTask = nil
        incomplete = true
        setLanguageSwitchingAllowed(false)
        liveSpeakers?.close()
        liveSpeakerEvents?.cancel()
        routingTask?.cancel()
        for run in runs {
            run.events.cancel()
            await run.channel.finish()
            await run.engine.cancelAndWait()
        }
        await routingTask?.value
        routingTask = nil
        runs.removeAll()
        activeRunID = nil
        eventTask?.cancel()
        diarizationTask?.cancel()
        await transcriber?.cancelAndWait()
        if let preparedSlot {
            await analyzerSlots.release(preparedSlot)
            self.preparedSlot = nil
        }
        eventTask = nil
        diarizationTask = nil
        transcriber = nil
        liveSpeakers = nil
        liveSpeakerEvents = nil
        currentMeetingId = nil
        diarizationIsRunning = false
        if status == .running || status == .preparing { status = .idle }
    }

    func speaker(for segment: ASRSegment) -> Speaker? {
        speakerProjection.speaker(utteranceID: segment.id)
    }

    var isIdentifyingSpeakers: Bool {
        speakerIdentificationProgress == .identifying
    }

    var speakerIdentificationProgress: SpeakerProjection.IdentificationProgress {
        if let progress = speakerProjection.identificationProgress { return progress }
        if let id = displayedMeetingID {
            switch services.speakerAnalysis.states[id] {
            case .preparing: return .pending
            case .analyzing: return .identifying
            case .complete, .failed: return .unassigned
            case nil: break
            }
        }
        return diarizationIsRunning && speakerWarning == nil ? .identifying : .unassigned
    }

    private func startSpeakerObservation(meetingID: String) {
        speakerObservationTask?.cancel()
        let database = services.database
        // Capture the model weakly for each delivery, not across the endless stream.
        // Observation belongs to the displayed recording, not an expanded panel.
        speakerObservationTask = Task { [weak self] in
            do {
                try await SpeakerProjection.observe(database: database, meetingID: meetingID) { [weak self] snapshot in
                    guard let self, displayedMeetingID == meetingID else { return }
                    speakerProjection = snapshot
                    speakerProjectionObservedAt = ProcessInfo.processInfo.systemUptime
                }
            } catch is CancellationError {
            } catch {
                RecordingDiagnostics.log(error)
            }
        }
    }

    func refreshSpeakerProjection() async throws {
        guard let id = displayedMeetingID else { return }
        let snapshot = try await SpeakerProjection.fetch(database: services.database, meetingID: id)
        guard displayedMeetingID == id else { return }
        speakerProjection = snapshot
    }

    private func apply(_ event: ASRTranscriptEvent, runID: UUID) async {
        switch event {
        case .ready(let info):
            guard runID == activeRunID else { return }
            status = .running
            computeUnit = "Apple Speech"
            detectedLanguage = info.language.fixedLocaleIdentifier
            effectiveLocale = info.language.fixedLocaleIdentifier.map(Locale.init(identifier:))
        case .segment(let segment):
            LiveIdentityTiming.record(.asrEvent)
            if let existing = lines.firstIndex(where: { $0.id == segment.id }) {
                lines[existing] = segment
            } else if !segment.text.isEmpty {
                lines.append(segment)
            }
            lines.sort { ($0.startMs, $0.id) > ($1.startMs, $1.id) }
            if runID == activeRunID, let locale = segment.localeIdentifier { detectedLanguage = locale }
            if segment.isFinal {
                do {
                    try await reconcileSpeakerAssignments()
                } catch {
                    processingFailure = String(describing: error)
                    RecordingDiagnostics.log(error)
                }
            }
        case .failed(let message):
            incomplete = true
            RecordingDiagnostics.log(message)
            if runID == activeRunID { status = .failed(RecordingLanguageText.speechFailure) }
            if let currentMeetingId {
                do {
                    try await RecordingProcessingRepository(services.database).recordFailure(
                        meetingId: currentMeetingId, error: message
                    )
                    await services.recordingFinalization.reload()
                } catch {
                    processingFailure = String(describing: error)
                    RecordingDiagnostics.log(error)
                }
            }
        case .finished:
            if runID == activeRunID, status == .running || status == .preparing { status = .idle }
        }
    }

    private func requireTranscriptProduced() async throws {
        guard let meetingId = currentMeetingId else { return }
        let utterances = try await UtteranceRepository(services.database).fetch(meetingId: meetingId)
        guard !utterances.isEmpty else { throw RecordingError.noTranscriptProduced }
    }

    /// Legacy diagnostics cannot authorize identities. Production consumes only
    /// completed-window dynamic events and reads the committed database projection.
    func apply(_ event: SpeakerDiarizer.Event, meetingId: String) async {
        guard currentMeetingId == meetingId else { return }
        switch event {
        case .ready:
            diarizationIsRunning = true
        case .finished:
            diarizationIsRunning = false
        case .failed(let message):
            diarizationIsRunning = false
            if status != .failed(message) {
                errorMessageForDiarization(message)
            }
        case .update(let finalized, let tentative):
            diarizationTimeline.apply(
                finalized: finalized, tentative: tentative
            )
            diarizationSegments = diarizationTimeline.segments
            do {
                try await refreshSpeakerProjection()
            } catch {
                errorMessageForDiarization(String(describing: error))
            }
        }
    }

    private func reconcileSpeakerAssignments() async throws {
        await liveSpeakers?.reconcile()
    }

    func apply(_ event: LiveSpeakerStatus, meetingId: String) async {
        guard currentMeetingId == meetingId else { return }
        diarizationIsRunning = event == .identifying
        speakerWarning = LiveSpeakerText.warning(event)
        if event == .published {
            LiveIdentityTiming.record(.publicationEvent)
        }
        if [.modelsUnavailable, .processingFailed, .storageFailed].contains(event) {
            RecordingDiagnostics.log("Optional live speakers: \(event)")
        }
    }

    private func errorMessageForDiarization(_ message: String) {
        RecordingDiagnostics.log(message)
        speakerWarning = RecordingLanguageText.speakerFailure
    }
}
