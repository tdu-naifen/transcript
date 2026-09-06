import Foundation
import Observation

@MainActor
@Observable
final class AppleSpeechResources {
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case failed(RecordingLanguageIssue)
    }

    private var states: [String: State] = [:]
    private var progress: [String: Double] = [:]
    private var currentKey: String?
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, any Error>?
    @ObservationIgnored private let install: @Sendable (Locale, @escaping @Sendable (Double?) async -> Void) async throws -> Void

    init(install: (@Sendable (Locale) async throws -> Void)? = nil) {
        self.install = { locale, progress in
            if let install { try await install(locale) }
            else { try await AppleLiveTranscriber.installResources(locale: locale, progress: progress) }
        }
    }

    init(installation: @escaping @Sendable (Locale, @escaping @Sendable (Double?) async -> Void) async throws -> Void) {
        self.install = installation
    }

    nonisolated static func key(for locale: Locale) -> String { locale.language.maximalIdentifier.lowercased() }
    func state(for locale: Locale) -> State { states[Self.key(for: locale)] ?? .idle }
    func fractionCompleted(for locale: Locale) -> Double? { progress[Self.key(for: locale)] }

    /// Latest choice wins. Cancellation never waits for an unresponsive system download.
    func prepare(locale: Locale) {
        _ = start(locale: locale)
    }

    func prepareAndWait(locale: Locale) async throws {
        try await start(locale: locale).value
        try Task.checkCancellation()
    }

    func cancel(locale: Locale) {
        guard currentKey == Self.key(for: locale) else { return }
        cancelCurrent()
    }

    private func cancelCurrent() {
        generation = UUID()
        task?.cancel()
        task = nil
        if let currentKey {
            states[currentKey] = .idle
            progress[currentKey] = nil
        }
        currentKey = nil
    }

    private func start(locale: Locale) -> Task<Void, any Error> {
        let key = Self.key(for: locale)
        if currentKey == key, let task { return task }
        cancelCurrent()
        let token = generation
        currentKey = key
        states[key] = .preparing
        let install = self.install
        let task = Task {
            do {
                try await install(locale) { [weak self] fraction in
                    await self?.updateProgress(fraction, key: key, token: token)
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                states[key] = .ready
                progress[key] = nil
                currentKey = nil
                self.task = nil
            } catch {
                if generation == token {
                    states[key] = error is CancellationError ? .idle : .failed(RecordingLanguageIssue(error))
                    progress[key] = nil
                    currentKey = nil
                    self.task = nil
                    RecordingDiagnostics.log(error)
                }
                throw error
            }
        }
        self.task = task
        return task
    }

    private func updateProgress(_ fraction: Double?, key: String, token: UUID) {
        guard generation == token else { return }
        progress[key] = fraction.map { min(1, max(0, $0)) }
    }
}
