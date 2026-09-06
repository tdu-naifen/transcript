import Foundation

enum MacLibraryError: LocalizedError {
    case unsupportedFormat
    case invalidAudio
    case audioUnavailable
    case emptyTitle
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "Choose an M4A audio file.")
        case .invalidAudio: String(localized: "The selected file does not contain readable M4A audio.")
        case .audioUnavailable: String(localized: "The audio file is not available on this Mac.")
        case .emptyTitle: String(localized: "Enter a meeting title.")
        case .cleanupFailed: String(localized: "The import failed, and its incomplete copy could not be removed.")
        }
    }
}
