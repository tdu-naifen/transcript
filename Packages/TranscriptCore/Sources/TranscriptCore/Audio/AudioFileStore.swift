import Foundation

/// Where recordings live: Application Support, because this is app-managed data the
/// user never files by hand — not Documents.
public struct AudioFileStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard(applicationSupport: URL? = nil) throws -> AudioFileStore {
        let base = try applicationSupport ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base
            .appendingPathComponent("Transcript", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AudioFileStore(directory: directory)
    }

    public func fileName(for meetingId: String) throws -> String {
        try "\(Self.validated(meetingId)).m4a"
    }

    public func url(forFileName fileName: String) throws -> URL {
        let name = try Self.validated(fileName.replacingOccurrences(of: ".m4a", with: ""))
        return directory.appendingPathComponent("\(name).m4a", isDirectory: false)
    }

    public func url(for meetingId: String) throws -> URL {
        try url(forFileName: fileName(for: meetingId))
    }

    public func exists(fileName: String) -> Bool {
        guard let url = try? url(forFileName: fileName) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func remove(fileName: String) throws {
        let url = try url(forFileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Meeting ids are UUIDs, but they arrive from the database, so the name is checked
    /// rather than trusted: anything outside `[A-Za-z0-9-_]` could escape the directory.
    private static func validated(_ component: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !component.isEmpty,
              component.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AudioCaptureError.invalidAudioFileName(component)
        }
        return component
    }
}
