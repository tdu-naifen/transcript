import Foundation
import Observation
import TranscriptCore

/// Owns stopped processors, never the current recorder or its UI state.
@MainActor
@Observable
final class RecordingFinalizationCoordinator {
    private(set) var jobs: [String: RecordingProcessingJob] = [:]
    private(set) var failures: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: RecordingSession.PendingStop] = [:]
    private var processorsRunning: Set<String> = []
    private var isActive = true
    private var foregroundWaiters: [CheckedContinuation<Void, Never>] = []
    private let repository: RecordingProcessingRepository
    private let session: RecordingSession

    init(database: AppDatabase, session: RecordingSession) {
        repository = RecordingProcessingRepository(database)
        self.session = session
    }

    func isBusy(_ id: String) -> Bool { tasks[id] != nil }
    var isSaturated: Bool { tasks.count >= 2 }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            let waiters = foregroundWaiters
            foregroundWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func awaitForeground() async {
        if !isActive { await withCheckedContinuation { foregroundWaiters.append($0) } }
    }

    func statusText(_ id: String) -> String? {
        if jobs[id]?.state == .needsRetry {
            return isBusy(id) ? RecordingProcessingText.retryWhileDraining : RecordingProcessingText.retry
        }
        if isBusy(id) { return RecordingProcessingText.processing }
        if failures[id] != nil { return RecordingProcessingText.retry }
        switch jobs[id]?.state {
        case .processing: return RecordingProcessingText.processing
        case .needsRetry, .interrupted: return RecordingProcessingText.retry
        default: return nil
        }
    }

    func reload() async {
        do {
            jobs = Dictionary(uniqueKeysWithValues: try await repository.fetchAll().map { ($0.meetingId, $0) })
            failures = failures.filter { jobs[$0.key] != nil && jobs[$0.key]?.state != .complete }
        } catch { RecordingDiagnostics.log(error) }
    }

    func recover() async throws {
        var live = await session.processingMeetingIDs
        if let capture = await session.activeMeetingId { live.insert(capture) }
        try await repository.interruptUnfinished(excluding: live)
        await reload()
    }

    func enqueue(
        token: RecordingSession.PendingStop?,
        meetingId: String,
        processor: any RecordingTranscriptionControlling,
        services: AppServices,
        library: LibraryModel,
        captureFailure: String?
    ) async {
        guard tasks[meetingId] == nil else { return }
        var persistenceFailure: String?
        let processingIssue = processor.processingIssue
        do {
            try await repository.update(
                meetingId: meetingId, state: processingIssue == nil ? .processing : .needsRetry,
                error: processingIssue
            )
        }
        catch {
            persistenceFailure = error.localizedDescription
            failures[meetingId] = error.localizedDescription
        }
        let enqueueFailure = persistenceFailure
        if let token { tokens[meetingId] = token }
        processorsRunning.insert(meetingId)
        tasks[meetingId] = Task {
            var failure = captureFailure ?? processingIssue ?? enqueueFailure
            if processor.needsForegroundFinalization { await awaitForeground() }
            do { try await processor.finish() }
            catch { failure = failure ?? error.localizedDescription }
            processorsRunning.remove(meetingId)
            if let token = tokens.removeValue(forKey: meetingId) {
                do {
                    let saved = try await session.publish(token, as: .recorded)
                    _ = try await MeetingRepository(services.database).refreshPrimaryLanguage(
                        id: saved.id, deviceId: services.deviceId
                    )
                    await services.speakerAnalysis.enqueue(saved)
                } catch { failure = failure ?? error.localizedDescription }
            }
            if let failure { failures[meetingId] = failure }
            do {
                try await repository.update(
                    meetingId: meetingId, state: failure == nil ? .complete : .needsRetry, error: failure
                )
            } catch {
                failures[meetingId] = error.localizedDescription
                RecordingDiagnostics.log(error)
            }
            tasks[meetingId] = nil
            await reload()
            await library.reload()
        }
        await reload()
    }

    func wait(meetingId: String) async { await tasks[meetingId]?.value }

    /// A failed archive write can be retried while its old processor still drains.
    /// Give that worker the token rather than releasing its per-meeting fence early.
    func adoptArchive(_ token: RecordingSession.PendingStop) async throws {
        if processorsRunning.contains(token.meetingId) {
            tokens[token.meetingId] = token
        } else {
            _ = try await session.publish(token, as: .recorded)
            try await repository.update(meetingId: token.meetingId, state: .needsRetry)
            await reload()
        }
    }
}

@MainActor
enum RecordingProcessingText {
    static var busy: String { text("This meeting’s transcript is still processing. Wait for it to finish, or fully close and reopen the app to interrupt processing, then retry deletion.") }
    static var processing: String { text("Audio saved. Finishing transcript…") }
    static var retry: String { text("Transcription needs retry. Saved audio and existing text are preserved. Use Reprocess to explicitly replace the transcript.") }
    static var retryWhileDraining: String { text("Audio saved. Transcription needs retry; cleanup is still running.") }
    static var mixed: String { text("This recording contains multiple languages. Whole-file retry is unavailable to avoid replacing it with the wrong language. Existing text and audio are unchanged.") }
    static var changed: String { text("The recording or transcript changed during processing. Nothing was replaced. Retry using the latest version.") }
    static func text(_ key: String) -> String {
        LocalizationManager.shared.text(key, table: "RecordingProcessing")
    }
}

/// Drain the capture broadcast promptly even when a speech engine hangs. Losing
/// inference input is explicit and recoverable from the independently saved file.
@MainActor
final class BoundedRecordingInput {
    let stream: AsyncStream<AudioChunk>
    private let task: Task<Void, Never>

    init(source: AsyncStream<AudioChunk>, onOverflow: @escaping @MainActor () -> Void) {
        let pair = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        stream = pair.stream
        task = Task {
            for await chunk in source {
                if Task.isCancelled { break }
                if case .dropped = pair.continuation.yield(chunk) { onOverflow() }
                if chunk.isFinal { break }
            }
            pair.continuation.finish()
        }
    }
}
