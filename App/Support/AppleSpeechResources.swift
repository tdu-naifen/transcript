import Foundation
import Observation

@MainActor
@Observable
final class AppleSpeechResources {
    enum State {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    private var states: [String: State] = [:]
    private var pending: [Locale] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let install: @Sendable (Locale) async throws -> Void

    init(install: @escaping @Sendable (Locale) async throws -> Void = { try await AppleLiveTranscriber.installResources(locale: $0) }) {
        self.install = install
    }

    func state(for locale: Locale) -> State { states[locale.identifier(.bcp47)] ?? .idle }

    /// System asset acquisition is independent of durable microphone capture.
    func prepare(locale: Locale) {
        switch state(for: locale) {
        case .preparing, .ready: return
        case .idle, .failed: break
        }
        states[locale.identifier(.bcp47)] = .preparing
        pending.append(locale)
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            while !pending.isEmpty {
                let locale = pending.removeFirst()
                do {
                    try await install(locale)
                    states[locale.identifier(.bcp47)] = .ready
                } catch {
                    states[locale.identifier(.bcp47)] = .failed(error.localizedDescription)
                }
            }
        }
    }
}
