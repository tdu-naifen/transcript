import Foundation
import TranscriptCore
import Synchronization

enum MeetingReprocessingConflict: Error {
    case recordingInProgress
    case anotherMeetingInProgress
}

actor MeetingReprocessingCoordinator {
    private let database: AppDatabase
    private let deviceId: String
    private let recordingSession: RecordingSession
    private var activeMeetingId: String?
    private var activeReprocessor: (any AppleFileTranscribing)?
    private var cancellation: ReprocessingCancellation?
    private let resources: AppleSpeechResources?
    private let makeTranscriber: @Sendable () -> any AppleFileTranscribing

    init(
        database: AppDatabase, deviceId: String, recordingSession: RecordingSession,
        resources: AppleSpeechResources? = nil,
        makeTranscriber: @escaping @Sendable () -> any AppleFileTranscribing = { AppleLiveTranscriber() }
    ) {
        self.database = database
        self.deviceId = deviceId
        self.recordingSession = recordingSession
        self.resources = resources
        self.makeTranscriber = makeTranscriber
    }

    func run(
        meetingId: String,
        audioURL: URL,
        language: ASRLanguage,
        progress: @escaping MeetingReprocessor.ProgressHandler
    ) async throws -> MeetingReprocessingSummary {
        guard activeMeetingId == nil else {
            throw MeetingReprocessingConflict.anotherMeetingInProgress
        }
        guard await recordingSession.activeMeetingId == nil else {
            throw MeetingReprocessingConflict.recordingInProgress
        }

        activeMeetingId = meetingId
        let reprocessor = makeTranscriber()
        let cancellation = ReprocessingCancellation()
        self.cancellation = cancellation
        activeReprocessor = reprocessor
        defer {
            activeMeetingId = nil
            activeReprocessor = nil
            self.cancellation = nil
        }
        await progress(.init(stage: .loadingAudio, fractionCompleted: 0))
        do {
            try await reprocessor.prepare(locale: Locale(identifier: language.fixedLocaleIdentifier ?? Locale.current.identifier))
            try cancellation.check()
            await progress(.init(stage: .transcribing, fractionCompleted: 0))
            let segments = try await reprocessor.transcribeFile(audioURL, meetingID: meetingId)
            try cancellation.check()
            guard !segments.isEmpty else { throw MeetingReprocessingError.noSpeechDetected }
            let previous = try await UtteranceRepository(database).fetch(meetingId: meetingId)
            let speakerIDs = Array(Set(previous.compactMap(\.speakerId))).sorted()
            let speakers = speakerIDs.enumerated().map {
                ReprocessedSpeakerDraft(speakerIndex: $0.offset, existingSpeakerId: $0.element)
            }
            let drafts = segments.map { segment in
                var overlaps: [String: Int] = [:]
                for utterance in previous {
                    guard let speakerID = utterance.speakerId else { continue }
                    let overlap = max(0, min(segment.endMs, utterance.endMs) - max(segment.startMs, utterance.startMs))
                    overlaps[speakerID, default: 0] += overlap
                }
                let best = overlaps.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first
                let speakerIndex = best.flatMap { best in
                    best.value > (segment.endMs - segment.startMs) / 2 ? speakerIDs.firstIndex(of: best.key) : nil
                }
                return ReprocessedUtteranceDraft(
                    startMs: segment.startMs, endMs: segment.endMs, text: segment.text,
                    speakerIndex: speakerIndex, localeIdentifier: segment.localeIdentifier
                )
            }
            await progress(.init(stage: .saving, fractionCompleted: 0.95))
            let result = try await MeetingReprocessingRepository(database).replace(
                meetingId: meetingId, utterances: drafts, speakers: speakers,
                deviceId: deviceId, engine: .appleSpeech,
                cancellationCheck: { try cancellation.check(); try Task.checkCancellation() }
            )
            return MeetingReprocessingSummary(
                utteranceCount: result.utteranceCount, speakerCount: result.speakerCount,
                identifiedSpeakerCount: 0, usedVoiceprintIdentification: false
            )
        } catch {
            await reprocessor.cancelAndWait()
            if case AppleLiveTranscriber.Failure.resourcesNotReady = error {
                await resources?.prepare(locale: Locale(identifier: language.fixedLocaleIdentifier ?? Locale.current.identifier))
            }
            throw error
        }
    }

    func cancel(meetingId: String) async {
        guard activeMeetingId == meetingId else { return }
        cancellation?.cancel()
        await activeReprocessor?.cancelAndWait()
    }
}

private final class ReprocessingCancellation: Sendable {
    private let cancelled = Mutex(false)
    func cancel() { cancelled.withLock { $0 = true } }
    func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}