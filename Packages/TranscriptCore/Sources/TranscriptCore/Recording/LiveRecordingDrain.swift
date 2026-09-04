import Foundation

public struct LiveRecordingDrainError: Error, Sendable, Equatable, CustomStringConvertible {
    public let failures: [String]

    public init(failures: [String]) {
        self.failures = failures
    }

    public var description: String { failures.joined(separator: "\n") }
}

/// Waits for both inference branches even when one fails, so neither branch loses its
/// final output while the recording is being sealed.
public enum LiveRecordingDrain {
    public static func wait(
        asr: @Sendable () async throws -> Void,
        diarization: @Sendable () async throws -> Void
    ) async throws {
        var failures: [String] = []
        do {
            try await asr()
        } catch {
            failures.append(String(describing: error))
        }
        do {
            try await diarization()
        } catch {
            failures.append(String(describing: error))
        }
        if !failures.isEmpty {
            throw LiveRecordingDrainError(failures: failures)
        }
    }
}