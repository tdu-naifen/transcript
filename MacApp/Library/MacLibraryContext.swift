import Foundation
import TranscriptCore

struct MacLibraryContext: Sendable {
    let database: AppDatabase
    let directory: URL
    let audioFiles: AudioFileStore
    let deviceID: String
}
