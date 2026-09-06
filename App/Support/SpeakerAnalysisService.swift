import Foundation
import Observation
import TranscriptCore
import UIKit

@MainActor
@Observable
final class SpeakerAnalysisService {
    enum State: Equatable {
        case preparing
        case analyzing
        case complete
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    private(set) var revision = 0
    private(set) var errorMessage: String?
    private let enabled: Bool
    private let jobs: SpeakerAnalysisRepository
    private let meetings: MeetingRepository
    private let store: AudioFileStore
    private let engine: any SpeakerAnalyzing
    private let fetchNext: @Sendable () async throws -> String?
    private var wakeup = UUID()
    @ObservationIgnored private var worker: Task<Void, Never>?
    private var isActive: Bool

    init(servicesDatabase: AppDatabase, deviceID: String, store: AudioFileStore, downloader: ASRModelDownloader, enabled: Bool, engine: (any SpeakerAnalyzing)? = nil, nextPending: (@Sendable () async throws -> String?)? = nil, isActive: Bool? = nil) {
        self.enabled = enabled
        self.isActive = isActive ?? (UIApplication.shared.applicationState == .active)
        let jobs = SpeakerAnalysisRepository(servicesDatabase)
        self.jobs = jobs
        self.fetchNext = nextPending ?? { try await jobs.nextPending() }
        meetings = MeetingRepository(servicesDatabase)
        self.store = store
        self.engine = engine ?? SpeakerAnalysisEngine(database: servicesDatabase, deviceID: deviceID, downloader: downloader)
    }

    func waitForIdle() async { await worker?.value }

    func setActive(_ active: Bool) {
        isActive = active
        if active { resume() }
        else { worker?.cancel() }
    }

    func enqueue(_ meeting: Meeting, retry: Bool = false) async {
        guard enabled, meeting.audioFileName != nil, meeting.state != .recording else { return }
        do {
            try await jobs.enqueue(meetingID: meeting.id, retry: retry)
            wakeup = UUID()
            if try await jobs.state(meetingID: meeting.id) == "complete" {
                states[meeting.id] = .complete
            } else if let reason = try await jobs.failure(meetingID: meeting.id) {
                RecordingDiagnostics.log(reason)
                states[meeting.id] = .failed(RecordingLanguageText.speakerFailure)
            } else {
                states[meeting.id] = .preparing
            }
            resume()
        } catch {
            RecordingDiagnostics.log(error)
            states[meeting.id] = .failed(RecordingLanguageText.speakerFailure)
            errorMessage = RecordingLanguageText.speakerFailure
        }
    }

    func resume() {
        guard enabled, isActive, worker == nil else { return }
        worker = Task {
            defer {
                worker = nil
                if Task.isCancelled, isActive { resume() }
            }
            do {
                while true {
                    try Task.checkCancellation()
                    guard isActive else { break }
                    let observedWakeup = wakeup
                    guard let id = try await fetchNext() else {
                        if observedWakeup != wakeup { continue }
                        break
                    }
                    try Task.checkCancellation()
                    try await jobs.setState(meetingID: id, state: "running")
                    states[id] = .preparing
                    do {
                        guard let meeting = try await meetings.fetch(id: id),
                              let name = meeting.audioFileName else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        let url = store.directory.appendingPathComponent(name)
                        try Task.checkCancellation()
                        guard isActive else { throw CancellationError() }
                        try await engine.run(meetingID: id, audioURL: url) { [weak self] stage in
                            await MainActor.run {
                                self?.states[id] = stage == .loadingAudio ? .preparing : .analyzing
                            }
                        }
                        states[id] = .complete
                        revision += 1
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            // The engine drains its child workers before returning. Never
                            // overlap generations or re-enroll a completed voiceprint pass.
                            let jobs = self.jobs
                            let deferred = try await Task {
                                guard try await jobs.state(meetingID: id) != "complete" else { return false }
                                try await jobs.setState(meetingID: id, state: "pending")
                                return true
                            }.value
                            if deferred {
                                states[id] = nil
                            }
                            break
                        }
                        RecordingDiagnostics.log(error)
                        let reason = error.localizedDescription
                        states[id] = .failed(RecordingLanguageText.speakerFailure)
                        try await jobs.setState(meetingID: id, state: "failed", error: reason)
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    RecordingDiagnostics.log(error)
                    errorMessage = RecordingLanguageText.speakerFailure
                }
            }
        }
    }
}
