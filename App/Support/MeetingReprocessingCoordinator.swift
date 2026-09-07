import Foundation
import TranscriptCore
import Synchronization

enum MeetingReprocessingConflict: Error {
    case recordingInProgress
    case anotherMeetingInProgress
    case mixedLanguages
}

struct MeetingReprocessingTimingFailure: LocalizedError {
    static let messageKey = "The replacement transcript has invalid times or extends beyond this meeting's saved recording duration. Your previous transcript, speaker assignments and original audio were kept. Keep this meeting and report it for repair before reprocessing again."
    let message: String
    var errorDescription: String? { message }
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
        guard await recordingSession.activeMeetingId != meetingId,
              !(await recordingSession.isProcessing(meetingId: meetingId)) else {
            throw MeetingReprocessingConflict.recordingInProgress
        }

        guard activeMeetingId == nil else { throw MeetingReprocessingConflict.anotherMeetingInProgress }
        activeMeetingId = meetingId
        let reservation: RecordingSession.PendingStop
        do { reservation = try await recordingSession.beginProcessing(meetingId: meetingId) }
        catch { activeMeetingId = nil; throw error }
        let slot: UUID
        do {
            guard let available = await RecordingAnalyzerSlots.shared.acquireIfAvailable() else {
                throw RecordingResourcesBusy()
            }
            slot = available
        } catch {
            activeMeetingId = nil
            _ = try? await recordingSession.publish(reservation, as: .recorded)
            throw error
        }
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
        var retryLocale = Locale(identifier: language.fixedLocaleIdentifier ?? Locale.current.identifier)
        do {
            let previous = try await UtteranceRepository(database).fetch(meetingId: meetingId)
            guard let meeting = try await MeetingRepository(database).fetch(id: meetingId) else {
                throw RepositoryError.notFound(table: Meeting.databaseTableName, id: meetingId)
            }
            let job = try await RecordingProcessingRepository(database).fetch(meetingId: meetingId)
            let locales = Set(previous.compactMap(\.localeIdentifier))
            guard locales.count <= 1, job?.requiresSegmentedRetry != true else {
                throw MeetingReprocessingConflict.mixedLanguages
            }
            let locale = locales.first ?? job?.localeIdentifier ?? meeting.localeIdentifier
                ?? language.fixedLocaleIdentifier ?? Locale.current.identifier
            retryLocale = Locale(identifier: locale)
            let snapshot = MeetingReprocessingSnapshot(audioSHA256: meeting.audioSHA256, utterances: previous)
            if let hash = meeting.audioSHA256 {
                guard try IncrementalSHA256.hashFile(at: audioURL).sha256 == hash else {
                    throw MeetingReprocessingSnapshotError.changed
                }
            }
            try await RecordingProcessingRepository(database).update(meetingId: meetingId, state: .processing)
            try await reprocessor.prepare(locale: retryLocale)
            try cancellation.check()
            await progress(.init(stage: .transcribing, fractionCompleted: 0))
            let segments = try await reprocessor.transcribeFile(
                audioURL, meetingID: meetingId, durationMs: meeting.durationMs
            )
            try cancellation.check()
            guard !segments.isEmpty else { throw MeetingReprocessingError.noSpeechDetected }
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
                expectedSnapshot: snapshot,
                cancellationCheck: { try cancellation.check(); try Task.checkCancellation() }
            )
            await reprocessor.cancelAndWait()
            await RecordingAnalyzerSlots.shared.release(slot)
            try await RecordingProcessingRepository(database).update(meetingId: meetingId, state: .complete)
            _ = try? await recordingSession.publish(reservation, as: .recorded)
            return MeetingReprocessingSummary(
                utteranceCount: result.utteranceCount, speakerCount: result.speakerCount,
                identifiedSpeakerCount: 0, usedVoiceprintIdentification: false
            )
        } catch {
            let reportedError: any Error
            if error is MeetingReprocessingTimingError || error is SavedRecordingAudioReader.Failure {
                reportedError = await MainActor.run {
                    MeetingReprocessingTimingFailure(message: LocalizationManager.shared.text(
                        MeetingReprocessingTimingFailure.messageKey, table: "MeetingCopy"
                    ))
                }
            } else {
                reportedError = error
            }
            await reprocessor.cancelAndWait()
            await RecordingAnalyzerSlots.shared.release(slot)
            _ = try? await recordingSession.publish(reservation, as: .recorded)
            try? await RecordingProcessingRepository(database).update(
                meetingId: meetingId, state: .needsRetry, error: reportedError.localizedDescription
            )
            if case AppleLiveTranscriber.Failure.resourcesNotReady = error {
                await resources?.prepare(locale: retryLocale)
            }
            throw reportedError
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