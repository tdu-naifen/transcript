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

/// Shared by live models, language replacements and manual file processing.
/// Cancelled preparations retain their lease until native cleanup actually finishes.
actor RecordingAnalyzerSlots {
    static let shared = RecordingAnalyzerSlots()
    private var held: Set<UUID> = []
    private var waiting: [(UUID, CheckedContinuation<UUID, any Error>)] = []

    func acquireIfAvailable() -> UUID? {
        guard held.count < 2, waiting.isEmpty else { return nil }
        let id = UUID()
        held.insert(id)
        return id
    }

    var count: Int { held.count }

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

struct RecordingResourcesBusy: LocalizedError {
    var errorDescription: String? {
        RecordingLanguageText.text("Speech engines are busy. Audio is being saved; retry transcription from the saved meeting.")
    }
}

/// A timed-out preparation retains its lease until the native operation actually
/// returns and cleanup drains. A deadline must not manufacture a third engine.
enum RecordingSpeechPreparation {
    static func prepare(
        _ engine: any AppleTranscribing, locale: Locale,
        slot: UUID, slots: RecordingAnalyzerSlots, timeout: Duration
    ) async throws {
        let gate = PreparationResult()
        let preparation = Task {
            do {
                try await engine.prepare(locale: locale)
                try Task.checkCancellation()
                if await gate.resolve(.success(())) { return }
            } catch {
                await engine.cancelAndWait()
                await slots.release(slot)
                _ = await gate.resolve(.failure(error))
                return
            }
            await engine.cancelAndWait()
            await slots.release(slot)
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            if await gate.resolve(.failure(RecordingResourcesBusy())) { preparation.cancel() }
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            Task {
                if await gate.resolve(.failure(CancellationError())) { preparation.cancel() }
            }
        }
        if Task.isCancelled {
            await engine.cancelAndWait()
            await slots.release(slot)
            throw CancellationError()
        }
    }

    private actor PreparationResult {
        private var result: Result<Void, any Error>?
        private var waiter: CheckedContinuation<Void, any Error>?
        func resolve(_ value: Result<Void, any Error>) -> Bool {
            guard result == nil else { return false }
            result = value
            waiter?.resume(with: value)
            waiter = nil
            return true
        }
        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
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
