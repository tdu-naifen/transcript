import Foundation
import Observation
import TranscriptCore

/// Backs `MeetingDetailView` (UI.md §3): transcript + speaker data for one meeting,
/// plus the audio player driving tap-to-seek and the current-line highlight.
@MainActor
@Observable
final class MeetingDetailModel {
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

    private let utteranceRepository: UtteranceRepository
    private let speakerRepository: SpeakerRepository
    private let meetingRepository: MeetingRepository
    private let deviceId: String

    init(meeting: Meeting, audioURL: URL?, services: AppServices, isRecordingActive: Bool = false) {
        self.meeting = meeting
        self.playback = AudioPlaybackModel(
            url: audioURL,
            durationMs: meeting.durationMs,
            isRecordingActive: isRecordingActive
        )
        self.utteranceRepository = UtteranceRepository(services.database)
        self.speakerRepository = SpeakerRepository(services.database)
        self.meetingRepository = MeetingRepository(services.database)
        self.deviceId = services.deviceId
    }

    /// Index into `utterances` of the line currently playing, for highlight + auto-scroll.
    var currentUtteranceId: String? {
        guard let index = TranscriptPlaybackPosition.currentIndex(
            utterances: utterances, atMs: playback.currentTimeMs
        ) else { return nil }
        return utterances[index].id
    }

    func load() async {
        do {
            async let fetchedUtterances = utteranceRepository.fetch(meetingId: meeting.id)
            async let fetchedSpeakers = speakerRepository.speakers(inMeeting: meeting.id)
            let (utterances, speakers) = try await (fetchedUtterances, fetchedSpeakers)
            self.utterances = utterances
            applySpeakers(speakers.map(\.speaker))
            loadFailure = nil
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
