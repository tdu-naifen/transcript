import Foundation
import Observation
import TranscriptCore

/// Backs `MeetingDetailView` (UI.md §3): transcript + speaker data for one meeting,
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
    let playback: AudioPlaybackModel

    private(set) var utterances: [Utterance] = []
    private(set) var participants: [ParticipantSummary] = []
    private(set) var speakersById: [String: Speaker] = [:]
    private(set) var loadFailure: String?
    private(set) var renamingSpeakerId: String?
    private(set) var reprocessingState: ReprocessingState = .idle

    private let utteranceRepository: UtteranceRepository
    private let speakerRepository: SpeakerRepository
    private let meetingRepository: MeetingRepository
    private let meetingReprocessor: MeetingReprocessingCoordinator
    private let audioURL: URL?
    private let reprocessingLanguage: ASRLanguage
    private let isRecordingActive: Bool
    private let deviceId: String
    private var reprocessingTask: Task<Void, Never>?
    private var pendingInitialSeekMs: Int?

    init(
        meeting: Meeting,
        audioURL: URL?,
        services: AppServices,
        isRecordingActive: Bool = false,
        initialSeekMs: Int? = nil
    ) {
        self.pendingInitialSeekMs = initialSeekMs
        self.meeting = meeting
        self.playback = AudioPlaybackModel(
            url: audioURL,
            durationMs: meeting.durationMs,
            isRecordingActive: isRecordingActive
        )
        self.utteranceRepository = UtteranceRepository(services.database)
        self.speakerRepository = SpeakerRepository(services.database)
        self.meetingRepository = MeetingRepository(services.database)
        self.meetingReprocessor = services.meetingReprocessor
        self.audioURL = audioURL
        self.reprocessingLanguage = services.asrLanguage
        self.isRecordingActive = isRecordingActive
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

    func load() async {
        do {
            async let fetchedUtterances = utteranceRepository.fetch(meetingId: meeting.id)
            async let fetchedSpeakers = speakerRepository.speakers(inMeeting: meeting.id)
            async let fetchedMeeting = meetingRepository.fetch(id: meeting.id)
            let (utterances, speakers, meeting) = try await (
                fetchedUtterances, fetchedSpeakers, fetchedMeeting
            )
            try Task.checkCancellation()
            self.utterances = utterances
            if let meeting { self.meeting = meeting }
            applySpeakers(speakers.map(\.speaker))
            loadFailure = nil
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

    /// Core interaction (UI.md §3b): tapping a transcript line jumps playback there.
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
        guard !isRecordingActive else {
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
                reprocessingState = .succeeded(summary)
            } catch is CancellationError {
                reprocessingState = .idle
            } catch {
                reprocessingState = .failed(reprocessingErrorMessage(error))
            }
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
        let locale = LocalizationManager.shared.resolvedLocale
        func localized(_ key: String) -> String {
            String(localized: String.LocalizationValue(key), table: "Reprocessing", locale: locale)
        }
        switch error {
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

    /// Renaming is iPhone-only and always allowed post-recording (UI.md §4.2); this
    /// screen is only ever reached post-recording. An empty name reverts to the
    /// anonymous animal name rather than storing a blank display name.
    func confirmRename(newName: String) async {
        guard let speakerId = renamingSpeakerId else { return }
        renamingSpeakerId = nil
        await renameSpeaker(id: speakerId, newName: newName)
    }

    func renameSpeaker(id speakerId: String, newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await speakerRepository.rename(
                id: speakerId, displayName: trimmed.isEmpty ? nil : trimmed, deviceId: deviceId
            )
            let speakers = try await speakerRepository.speakers(inMeeting: meeting.id)
            applySpeakers(speakers.map(\.speaker))
        } catch {
            loadFailure = String(describing: error)
        }
    }

    private func applySpeakers(_ speakers: [Speaker]) {
        speakersById = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        let percentages = SpeakerTalkShare.percentages(
            utterances: utterances, speakerIds: speakers.map(\.id)
        )
        participants = speakers.map { speaker in
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
