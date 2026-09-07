import Foundation
import Observation
import TranscriptCore

struct SpeakerRenameAction: Equatable, Sendable {
    let speakerId: String
    let name: String
}

/// Backs `MeetingDetailView`: transcript + speaker data for one meeting,
/// plus the audio player driving tap-to-seek and the current-line highlight.
@MainActor
@Observable
final class MeetingDetailModel {
    enum ReprocessingState: Equatable {
        case idle
        case running(MeetingReprocessingProgress)
        case succeeded(MeetingReprocessingSummary)
        case failed(String)
    }

    struct ParticipantSummary: Identifiable, Equatable {
        let id: String
        var resolvedName: String
        let colorIndex: Int
        let percentage: Int
        var hasCustomName: Bool
    }

    private(set) var meeting: Meeting
    private(set) var playback: AudioPlaybackModel
    let speakerAnalysis: SpeakerAnalysisService
    let recordingFinalization: RecordingFinalizationCoordinator

    private(set) var utterances: [Utterance] = []
    private(set) var participants: [ParticipantSummary] = []
    private(set) var speakersById: [String: Speaker] = [:]
    private(set) var loadFailure: String?
    private(set) var renamingSpeakerId: String?
    private(set) var failedSpeakerRename: SpeakerRenameAction?
    private(set) var speakerRenameFailure: String?
    private var renameRequestID = UUID()
    private(set) var reprocessingState: ReprocessingState = .idle
    private(set) var speakerProjection = SpeakerProjection.empty
    private(set) var sessionPhase: RecordingSession.Phase = .idle
    private(set) var isCurrentRecording = false
    private(set) var isDeleted = false

    private let database: AppDatabase
    private let session: RecordingSession
    private let speakerRepository: SpeakerRepository
    private let meetingRepository: MeetingRepository
    private let meetingReprocessor: MeetingReprocessingCoordinator
    private(set) var audioURL: URL?
    private let audioStore: AudioFileStore
    private let audioOwnership: AudioSessionOwnership
    private let reprocessingLanguage: ASRLanguage
    private let recordingIsActive: @MainActor () -> Bool
    private let deviceId: String
    private var reprocessingTask: Task<Void, Never>?
    private var pendingInitialSeekMs: Int?
    private var requestedSpeakerAnalysis = false
    private var isRequestingSpeakerAnalysis = false
    private var isRetryingSpeakerAnalysis = false

    init(
        meeting: Meeting,
        audioURL: URL?,
        services: AppServices,
        isRecordingActive: Bool = false,
        initialSeekMs: Int? = nil,
        recordingIsActive: (@MainActor () -> Bool)? = nil,
        speakerAnalysisService: SpeakerAnalysisService? = nil
    ) {
        self.pendingInitialSeekMs = initialSeekMs
        self.meeting = meeting
        self.playback = AudioPlaybackModel(
            url: audioURL,
            durationMs: meeting.durationMs,
            isRecordingActive: isRecordingActive,
            recordingIsActive: recordingIsActive,
            audioOwnership: services.audioOwnership
        )
        self.database = services.database
        self.session = services.session
        self.speakerRepository = SpeakerRepository(services.database)
        self.meetingRepository = MeetingRepository(services.database)
        self.meetingReprocessor = services.meetingReprocessor
        self.speakerAnalysis = speakerAnalysisService ?? services.speakerAnalysis
        self.recordingFinalization = services.recordingFinalization
        self.audioURL = audioURL
        self.audioStore = services.store
        self.audioOwnership = services.audioOwnership
        self.reprocessingLanguage = services.asrLanguage
        self.recordingIsActive = {
            services.audioOwnership.isCaptureReserved || (recordingIsActive?() ?? isRecordingActive)
        }
        self.deviceId = services.deviceId
    }

    /// Index into `utterances` of the line currently playing, for highlight + auto-scroll.
    var currentUtteranceId: String? {
        guard let index = TranscriptPlaybackPosition.currentIndex(
            utterances: utterances, atMs: playback.currentTimeMs
        ) else { return nil }
        return utterances[index].id
    }

    var hasLocalAudioForReprocessing: Bool {
        guard let audioURL else { return false }
        return FileManager.default.fileExists(atPath: audioURL.path)
    }

    var isReprocessing: Bool {
        if case .running = reprocessingState { return true }
        return false
    }

    var displayDurationMs: Int {
        max(meeting.durationMs, speakerProjection.extentMs)
    }

    var speakerIdentificationProgress: SpeakerProjection.IdentificationProgress {
        if let progress = speakerProjection.identificationProgress { return progress }
        switch speakerAnalysis.states[meeting.id] {
        case .preparing: return .pending
        case .analyzing: return .identifying
        default: return .unassigned
        }
    }

    var resolvedSpeakerAnalysisState: SpeakerAnalysisService.State? {
        switch speakerProjection.analysisState {
        case "failed": return .failed(RecordingLanguageText.speakerFailure)
        case "complete": return .complete
        case "pending", "rerun": return .preparing
        case "running":
            if speakerAnalysis.states[meeting.id] == .preparing { return .preparing }
            return .analyzing
        default: return speakerAnalysis.states[meeting.id]
        }
    }

    var canRetrySpeakerAnalysis: Bool {
        guard case .failed = resolvedSpeakerAnalysisState else { return false }
        return !isRetryingSpeakerAnalysis && !isCurrentRecording
    }

    func retrySpeakerAnalysis() async {
        guard canRetrySpeakerAnalysis else { return }
        isRetryingSpeakerAnalysis = true
        defer { isRetryingSpeakerAnalysis = false }
        guard await session.activeMeetingId != meeting.id,
              !(await session.isProcessing(meetingId: meeting.id)) else { return }
        await speakerAnalysis.enqueue(meeting, retry: true)
        await load()
    }

    var recordingStatusText: String? {
        if let status = recordingFinalization.statusText(meeting.id) { return status }
        let key: String
        if isCurrentRecording {
            switch sessionPhase {
            case .recording: key = "Recording in progress"
            case .paused: key = "Recording paused"
            case .idle:
                key = speakerProjection.hasDurableArchive
                    ? "Audio saved. Finishing transcript…"
                    : "Finishing recording…"
            }
        } else if meeting.state == .recording {
            key = "Recording is not finalized"
        } else if meeting.durationMs == 0, displayDurationMs > 0 {
            key = "Duration shown from available transcript"
        } else {
            return nil
        }
        return LocalizationManager.shared.text(key, table: "SpeakerProjection")
    }

    func speaker(for utterance: Utterance) -> Speaker? {
        speakerProjection.speaker(utteranceID: utterance.id)
    }

    func observe() async {
        await load()
        do {
            try await SpeakerProjection.observe(database: database, meetingID: meeting.id) { [weak self] snapshot in
                self?.applyProjection(snapshot)
            }
        } catch is CancellationError {
        } catch {
            loadFailure = String(describing: error)
        }
    }

    /// Session state is actor-owned, not Observable. Poll only while this screen is
    /// visible; this neither subscribes to microphone samples nor acquires audio.
    func observeRecordingState() async {
        while !Task.isCancelled {
            let id = await session.activeMeetingId
            let phase = await session.currentPhase
            isCurrentRecording = id == meeting.id
            sessionPhase = isCurrentRecording ? phase : .idle
            if !isCurrentRecording { await enqueueSpeakerAnalysisIfReady() }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
        }
    }

    func load() async {
        do {
            let snapshot = try await SpeakerProjection.fetch(database: database, meetingID: meeting.id)
            try Task.checkCancellation()
            applyProjection(snapshot)
            await enqueueSpeakerAnalysisIfReady()
            // Consume once after data is ready, not on every appearance or reload.
            if let initialSeekMs = pendingInitialSeekMs {
                pendingInitialSeekMs = nil
                playback.seekAndPlay(toMs: initialSeekMs)
            }
        } catch is CancellationError {
            return
        } catch {
            loadFailure = String(describing: error)
        }
    }

    private func enqueueSpeakerAnalysisIfReady() async {
        guard !requestedSpeakerAnalysis, !isRequestingSpeakerAnalysis,
              meeting.audioFileName != nil, speakerProjection.analysisState == nil else { return }
        isRequestingSpeakerAnalysis = true
        defer { isRequestingSpeakerAnalysis = false }
        // A durable archive can be played while ASR still drains. Only publication
        // releases the transcript fence; capture's idle phase is not sufficient.
        guard await session.activeMeetingId != meeting.id,
              !(await session.isProcessing(meetingId: meeting.id)) else { return }
        do {
            let snapshot = try await SpeakerProjection.fetch(database: database, meetingID: meeting.id)
            try Task.checkCancellation()
            guard let saved = snapshot.meeting, saved.state != .recording, saved.audioFileName != nil,
                  snapshot.analysisState == nil,
                  snapshot.observedSpeakers.isEmpty || snapshot.utterances.contains(where: { $0.speakerId == nil })
            else { return }
            requestedSpeakerAnalysis = true
            // Existing jobs, including deliberately unresolved completed results,
            // are never retried merely because their detail screen was opened.
            await speakerAnalysis.enqueue(saved)
        } catch is CancellationError {
        } catch {
            RecordingDiagnostics.log(error)
        }
    }

    private func applyProjection(_ snapshot: SpeakerProjection) {
        speakerProjection = snapshot
        utterances = snapshot.utterances
        guard let savedMeeting = snapshot.meeting else {
            isDeleted = true
            playback.stop()
            audioURL = nil
            playback = AudioPlaybackModel(
                url: nil, durationMs: 0,
                recordingIsActive: recordingIsActive, audioOwnership: audioOwnership
            )
            applySpeakers([])
            return
        }
        isDeleted = false
        meeting = savedMeeting
        let resolvedURL = meeting.audioFileName.map { audioStore.directory.appendingPathComponent($0) } ?? audioURL
        let playbackDuration = meeting.durationMs > 0 ? meeting.durationMs : displayDurationMs
        if resolvedURL != audioURL || playback.durationMs != playbackDuration {
            playback.stop()
            audioURL = resolvedURL
            playback = AudioPlaybackModel(
                url: resolvedURL, durationMs: playbackDuration,
                recordingIsActive: recordingIsActive, audioOwnership: audioOwnership
            )
        }
        applySpeakers(snapshot.speakers)
        loadFailure = nil
    }

    /// Tapping a transcript line jumps playback there.
    func seek(to utterance: Utterance) {
        playback.seekAndPlay(toMs: utterance.startMs)
    }

    func beginRename(speakerId: String) {
        renamingSpeakerId = speakerId
    }

    func cancelRename() {
        renamingSpeakerId = nil
    }

    func startReprocessing() {
        guard reprocessingTask == nil, hasLocalAudioForReprocessing, let audioURL else { return }
        guard !isCurrentRecording, !recordingFinalization.isBusy(meeting.id) else {
            reprocessingState = .failed(String(describing: MeetingReprocessingConflict.recordingInProgress))
            return
        }
        reprocessingState = .running(.init(stage: .loadingAudio, fractionCompleted: 0))
        reprocessingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await meetingReprocessor.run(
                    meetingId: meeting.id,
                    audioURL: audioURL,
                    language: reprocessingLanguage
                ) { [weak self] progress in
                    await MainActor.run { self?.reprocessingState = .running(progress) }
                }
                try Task.checkCancellation()
                await load()
                await speakerAnalysis.enqueue(meeting, retry: true)
                reprocessingState = .succeeded(summary)
            } catch is CancellationError {
                reprocessingState = .idle
            } catch {
                reprocessingState = .failed(reprocessingErrorMessage(error))
            }
            await recordingFinalization.reload()
            reprocessingTask = nil
        }
    }

    func cancelReprocessing() {
        guard reprocessingTask != nil else { return }
        reprocessingTask?.cancel()
        Task { await meetingReprocessor.cancel(meetingId: meeting.id) }
    }

    func dismissReprocessingResult() {
        guard !isReprocessing else { return }
        reprocessingState = .idle
    }

    private func reprocessingErrorMessage(_ error: any Error) -> String {
        func localized(_ key: String) -> String {
            LocalizationManager.shared.text(key, table: "Reprocessing")
        }
        switch error {
        case MeetingReprocessingConflict.mixedLanguages:
            return RecordingProcessingText.mixed
        case MeetingReprocessingSnapshotError.changed:
            return RecordingProcessingText.changed
        case MeetingReprocessingConflict.recordingInProgress:
            return localized("Stop recording before reprocessing.")
        case MeetingReprocessingConflict.anotherMeetingInProgress,
             MeetingReprocessingError.alreadyRunning:
            return localized("Another meeting is already being reprocessed.")
        case MeetingReprocessingError.missingASRModel,
             MeetingReprocessingError.missingDiarizationModel:
            return localized("Required models are not installed.")
        case MeetingReprocessingError.noSpeechDetected:
            return localized("No speech was detected. The current transcript was kept.")
        case MeetingReprocessingError.transcriptionFailed(let detail):
            return "\(localized("Transcription failed.")) \(detail)"
        case MeetingReprocessingError.speakerDetectionFailed(let detail):
            return "\(localized("Speaker detection failed.")) \(detail)"
        case MeetingReprocessingError.speakerIdentificationFailed(let detail):
            return "\(localized("Known-speaker identification failed.")) \(detail)"
        default:
            return error.localizedDescription
        }
    }

    @discardableResult
    func updateEmoji(_ emoji: String) async -> Bool {
        do {
            meeting = try await meetingRepository.setEmoji(id: meeting.id, emoji: emoji, deviceId: deviceId)
            return true
        } catch {
            loadFailure = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameMeeting(newTitle: String) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            meeting = try await meetingRepository.rename(
                id: meeting.id, title: trimmed, deviceId: deviceId
            )
            return true
        } catch {
            loadFailure = String(describing: error)
            return false
        }
    }

    /// Renames the global speaker by stable ID; authorized sync propagates the
    /// change to paired devices. An empty name reverts to the anonymous animal name
    /// rather than storing a blank display name.
    func renameSpeaker(id speakerId: String, newName: String) async {
        await renameSpeaker(action: SpeakerRenameAction(speakerId: speakerId, name: newName))
    }

    func dismissSpeakerRenameFailure() { speakerRenameFailure = nil }

    func renameSpeaker(action: SpeakerRenameAction) async {
        let requestID = UUID()
        renameRequestID = requestID
        speakerRenameFailure = nil
        failedSpeakerRename = nil
        let trimmed = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await speakerRepository.rename(
                id: action.speakerId, displayName: trimmed.isEmpty ? nil : trimmed, deviceId: deviceId
            )
            let snapshot = try await SpeakerProjection.fetch(database: database, meetingID: meeting.id)
            guard renameRequestID == requestID else { return }
            applyProjection(snapshot)
        } catch {
            guard renameRequestID == requestID else { return }
            failedSpeakerRename = action
            speakerRenameFailure = error.localizedDescription
        }
    }

    private func applySpeakers(_ speakers: [Speaker]) {
        speakersById = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        let percentages = SpeakerTalkShare.percentages(
            utterances: utterances, speakerIds: speakers.map(\.id)
        )
        let observedIDs = Set(utterances.filter { $0.endMs > $0.startMs }.compactMap(\.speakerId))
        participants = speakers.filter { observedIDs.contains($0.id) }.map { speaker in
            ParticipantSummary(
                id: speaker.id,
                resolvedName: speaker.resolvedName,
                colorIndex: speaker.colorIndex,
                percentage: percentages[speaker.id] ?? 0,
                hasCustomName: speaker.displayName != nil
            )
        }
    }
}
