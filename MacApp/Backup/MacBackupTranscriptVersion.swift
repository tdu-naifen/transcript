import Foundation

/// Export-only data: deliberately excludes processing inputs, model locations,
/// bookmarks, errors, and runtime configuration.
struct MacBackupTranscriptVersion: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case readyForReview, savedLocally
    }

    struct Model: Codable, Equatable, Sendable {
        let repository: String
        let expectedRepositoryRevision: String
        let localContentSHA256: String
    }

    struct Segment: Codable, Equatable, Sendable {
        let id: String
        let startMs: Int
        let endMs: Int
        let text: String
        let localeIdentifier: String?
        let createdAt: Date
        let updatedAt: Date
    }

    let id: UUID
    let meetingID: String
    let createdAt: Date
    let state: State
    let sourceAudioSHA256: String
    let sourceAudioByteCount: Int
    let title: String
    let startedAt: Date
    let durationMs: Int
    let language: String
    let models: [Model]
    let segments: [Segment]
}
