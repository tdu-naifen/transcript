import Foundation
import OSLog
import TranscriptCore

enum RecordingLanguageText {
    static var resourceFailure: String { text("Language setup could not finish. Retry or choose another language.") }
    static var resourcesNeeded: String { text("Audio is being saved. Prepare a language to enable transcription during this meeting.") }
    static var speechFailure: String { text("Transcription is unavailable. Audio recording continues.") }
    static var speakerFailure: String { text("Speaker labels are unavailable. Audio and transcription are unaffected.") }
    static func text(_ key: String) -> String {
        let locale = AppLanguage.current.locale
        let bundle = locale.flatMap { Bundle.main.path(forResource: $0.identifier, ofType: "lproj") }
            .flatMap(Bundle.init(path:)) ?? .main
        return String(localized: String.LocalizationValue(key), table: "RecordingLanguage", bundle: bundle, locale: locale ?? .autoupdatingCurrent)
    }
}

enum RecordingDiagnostics {
    private static let logger = Logger(subsystem: "com.transcript.Transcript", category: "Recording")
    nonisolated static func log(_ error: any Error) { log(String(describing: error)) }
    nonisolated static func log(_ message: String) { logger.error("\(message, privacy: .private)") }
}

struct RecordingLanguageIssue: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case resourceSetup
        case unavailable
        case unsupportedLanguage
        case permissionDenied
        case invalidAudio
        case resourcesNeeded
    }

    let reason: Reason
    let technicalDetails: String

    init(_ error: any Error, preserveSpeechReason: Bool = false) {
        technicalDetails = String(describing: error)
        guard preserveSpeechReason, let failure = error as? AppleLiveTranscriber.Failure else {
            reason = .resourceSetup
            return
        }
        switch failure {
        case .unavailable: reason = .unavailable
        case .unsupportedLanguage: reason = .unsupportedLanguage
        case .permissionDenied: reason = .permissionDenied
        case .invalidAudio: reason = .invalidAudio
        case .resourcesNotReady: reason = .resourcesNeeded
        }
    }

    @MainActor var text: String {
        let localization = LocalizationManager.shared
        switch reason {
        case .resourceSetup:
            return localization.text("Language setup could not finish. Retry or choose another language.", table: "RecordingLanguage")
        case .resourcesNeeded:
            return localization.text("Audio is being saved. Prepare a language to enable transcription during this meeting.", table: "RecordingLanguage")
        case .unavailable:
            return localization.text("Apple on-device transcription is unavailable on this device. Audio recording is still available.", table: "AppleSpeech")
        case .unsupportedLanguage:
            return localization.text("Apple transcription does not support the selected recording language. Audio recording is still available.", table: "AppleSpeech")
        case .permissionDenied:
            return localization.text("Speech recognition access is off. Enable it in Settings to transcribe. Audio recording is still available.", table: "AppleSpeech")
        case .invalidAudio:
            return localization.text("The audio could not be converted for Apple transcription.", table: "AppleSpeech")
        }
    }
}

struct RecordingSpeechUnavailable: LocalizedError {
    var errorDescription: String? {
        RecordingLanguageText.text("Transcription ended early. Your recorded audio is saved.")
    }
}

/// Current speech plus one preparing/retiring engine. A cancelled preparation
/// keeps its lease until cleanup finishes; stale work cannot create a third analyzer.
actor RecordingAnalyzerSlots {
    private var held: Set<UUID> = []
    private var waiting: [(UUID, CheckedContinuation<UUID, any Error>)] = []

    func acquire() async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if held.count < 2 {
                    held.insert(id)
                    continuation.resume(returning: id)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    func release(_ id: UUID) {
        guard held.remove(id) != nil else { return }
        if !waiting.isEmpty {
            let (id, continuation) = waiting.removeFirst()
            held.insert(id)
            continuation.resume(returning: id)
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
}

/// A rendezvous channel: the router cannot outrun an analyzer, or lose a handoff chunk.
/// Closing drains the already accepted chunk; cancellation releases both waiters.
actor RecordingChunkChannel {
    private var pending: AudioChunk?
    private var sender: CheckedContinuation<Void, Never>?
    private var receiver: CheckedContinuation<AudioChunk?, Never>?
    private var closed = false

    nonisolated var stream: AsyncStream<AudioChunk> {
        AsyncStream(unfolding: { await self.next() })
    }

    func send(_ chunk: AudioChunk) async {
        guard !closed else { return }
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: chunk)
        } else {
            pending = chunk
            await withCheckedContinuation { sender = $0 }
        }
    }

    private func next() async -> AudioChunk? {
        if let pending {
            self.pending = nil
            sender?.resume()
            sender = nil
            return pending
        }
        if closed { return nil }
        return await withCheckedContinuation { receiver = $0 }
    }

    func finish() {
        closed = true
        receiver?.resume(returning: nil)
        receiver = nil
        sender?.resume()
        sender = nil
    }
}
