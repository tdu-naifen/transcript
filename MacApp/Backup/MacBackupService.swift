import Darwin
import Foundation
import GRDB
import TranscriptCore

struct MacBackupManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
        let byteCount: Int
    }

    let formatVersion: Int
    let createdAt: Date
    let appVersion: String
    let schemaMigrations: [String]
    let meetingCount: Int
    let audioCount: Int
    let transcriptVersionCount: Int?
    let files: [File]
}

enum MacBackupError: LocalizedError {
    case unsafePath(String)
    case invalidAudio(String)
    case invalidSnapshot
    case unavailableFolder
    case invalidTranscriptVersion

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            String(localized: "Unsafe backup path: \(path)", table: "Backup")
        case .invalidAudio(let name):
            String(localized: "Missing, changed, or unverified audio: \(name). No backup was published.", table: "Backup")
        case .invalidSnapshot:
            String(localized: "Snapshot verification failed. Files, checksums, or database integrity do not match.", table: "Backup")
        case .unavailableFolder:
            String(localized: "The backup folder is unavailable. Reconnect the drive or choose the folder again.", table: "Backup")
        case .invalidTranscriptVersion:
            String(localized: "A completed local transcript version is corrupt or changed during backup. No backup was published. Try again after processing finishes.", table: "Backup")
        }
    }
}

final class MacBackupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Synchronous filesystem/database work. Call only from a worker, never the main actor.
enum MacBackupService {
    private static let versionsPath = "transcript-versions.json"
    private static let jsonLimit = 16 * 1_024 * 1_024
    private static let versionsLimit = 64 * 1_024 * 1_024
    private struct Metadata {
        let meetings: [Meeting]
        let migrations: [String]
    }

    static func create(
        context: MacLibraryContext,
        destination: URL,
        cancellation: MacBackupCancellation = MacBackupCancellation()
    ) throws -> URL {
        try cancellation.check()
        try validateDestination(destination, context: context)
        let fm = FileManager.default
        let stagingRoot = context.directory.appendingPathComponent(".BackupStaging", isDirectory: true)
        try validatePath(stagingRoot)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }

        let databaseURL = stage.appendingPathComponent("transcript.sqlite")
        try makeDatabaseSnapshot(context.database, at: databaseURL, cancellation: cancellation)
        let metadata = try readMetadata(at: databaseURL)
        let audio = try audioReferences(metadata.meetings)
        try fm.createDirectory(at: stage.appendingPathComponent("Audio"), withIntermediateDirectories: false)
        var files = [try digest(databaseURL, path: "transcript.sqlite", cancellation: cancellation)]
        for reference in audio {
            try cancellation.check()
            let source = try context.audioFiles.url(forFileName: reference.path)
            guard source.lastPathComponent == reference.path else {
                throw MacBackupError.unsafePath(reference.path)
            }
            let relativePath = "Audio/" + reference.path
            do {
                let result = try copyFile(
                    from: source, to: stage.appendingPathComponent(relativePath),
                    path: relativePath, cancellation: cancellation
                )
                guard result.sha256 == reference.sha256, result.byteCount == reference.byteCount else {
                    throw MacBackupError.invalidAudio(reference.path)
                }
                files.append(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MacBackupError.invalidAudio(reference.path)
            }
        }
        let versions = try captureTranscriptVersions(
            context: context, meetings: metadata.meetings, cancellation: cancellation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let versionBytes = try encoder.encode(versions)
        guard versionBytes.count <= versionsLimit else { throw MacBackupError.invalidTranscriptVersion }
        let versionsURL = stage.appendingPathComponent(versionsPath)
        try versionBytes.write(to: versionsURL, options: .atomic)
        files.append(try digest(versionsURL, path: versionsPath, cancellation: cancellation))
        let manifest = MacBackupManifest(
            formatVersion: 2, createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            schemaMigrations: metadata.migrations,
            meetingCount: metadata.meetings.count, audioCount: audio.count,
            transcriptVersionCount: versions.count,
            files: files.sorted { $0.path < $1.path }
        )
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try verifyPackage(at: stage, cancellation: cancellation)
        return try publish(stage: stage, destination: destination, context: context, cancellation: cancellation)
    }

    static func verify(
        snapshot: URL,
        cancellation: MacBackupCancellation = MacBackupCancellation()
    ) throws -> MacBackupManifest {
        var outcome: Result<MacBackupManifest, any Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: snapshot, options: .withoutChanges, error: &coordinationError) { url in
            outcome = Result { try verifyPackage(at: url, cancellation: cancellation) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw MacBackupError.unavailableFolder }
        return try outcome.get()
    }

    static func validateDestination(_ destination: URL, context: MacLibraryContext) throws {
        try validatePath(destination)
        for root in [context.directory, context.audioFiles.directory] {
            let source = root.standardizedFileURL.resolvingSymlinksInPath().path
            let target = destination.standardizedFileURL.path
            guard target != source, !target.hasPrefix(source + "/") else {
                throw MacBackupError.unsafePath(destination.path)
            }
        }
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard values.isDirectory == true, values.isWritable == true else {
            throw MacBackupError.unavailableFolder
        }
    }

    private static func makeDatabaseSnapshot(
        _ database: AppDatabase, at url: URL, cancellation: MacBackupCancellation
    ) throws {
        let snapshot = try DatabaseQueue(path: url.path)
        defer { try? snapshot.close() }
        // SQLite's backup transaction captures one coherent database version. Audio
        // references are read ONLY from that version, not from a later live query.
        try database.reader.backup(to: snapshot, pagesPerStep: 128) { _ in
            try cancellation.check()
        }
        try cancellation.check()
        try snapshot.writeWithoutTransaction { db in
            guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
                throw MacBackupError.invalidSnapshot
            }
        }
        try snapshot.close()
        // Switching a backed-up WAL database to DELETE can leave an orphan shared
        // memory index. All connections are closed and DELETE mode has checkpointed
        // the database; this staging-only index is not part of the snapshot.
        let sharedMemory = URL(fileURLWithPath: url.path + "-shm")
        if FileManager.default.fileExists(atPath: sharedMemory.path) {
            try FileManager.default.removeItem(at: sharedMemory)
        }
    }

    private static func readMetadata(at url: URL) throws -> Metadata {
        // A read-only SQLite connection can still create WAL/SHM sidecars. Our
        // format only accepts checkpointed, rollback-journal databases.
        let input = try openRegularFile(url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 100) ?? Data()
        guard header.count == 100,
              header.prefix(16) == Data("SQLite format 3\0".utf8),
              header[18] == 1, header[19] == 1 else {
            throw MacBackupError.invalidSnapshot
        }
        var config = Configuration()
        config.readonly = true
        let snapshot = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? snapshot.close() }
        return try snapshot.read { db in
            guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw MacBackupError.invalidSnapshot
            }
            return Metadata(
                meetings: try Meeting.fetchAll(db),
                migrations: try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            )
        }
    }

    private static func audioReferences(_ meetings: [Meeting]) throws -> [MacBackupManifest.File] {
        var references: [String: MacBackupManifest.File] = [:]
        for meeting in meetings {
            guard let name = meeting.audioFileName else {
                guard meeting.audioSHA256 == nil, meeting.audioByteCount == nil else {
                    throw MacBackupError.invalidAudio(meeting.id)
                }
                continue
            }
            guard isAudioName(name),
                  let hash = meeting.audioSHA256, isSHA256(hash),
                  let count = meeting.audioByteCount, count > 0 else {
                throw MacBackupError.invalidAudio(name)
            }
            let file = MacBackupManifest.File(path: name, sha256: hash, byteCount: count)
            if let previous = references[name], previous != file { throw MacBackupError.invalidAudio(name) }
            references[name] = file
        }
        return references.values.sorted { $0.path < $1.path }
    }

    private struct ProcessingEnvelope: Decodable {
        let version: Int
        let id: UUID
        let meetingID: String
        let state: String
    }

    private struct ProcessingSource: Decodable {
        struct Transcript: Decodable {
            let meeting: Meeting
            let utterances: [Utterance]
        }
        let createdAt: Date
        let audioSHA256: String
        let audioByteCount: Int
        let language: String
        let models: [MacBackupTranscriptVersion.Model]
        let previous: Transcript
        let proposal: Transcript
    }

    private static func captureTranscriptVersions(
        context: MacLibraryContext, meetings: [Meeting], cancellation: MacBackupCancellation
    ) throws -> [MacBackupTranscriptVersion] {
        let root = context.directory.appendingPathComponent("MacProcessing", isDirectory: true)
        try validatePath(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        guard entries.count <= 10_000 else { throw MacBackupError.invalidTranscriptVersion }
        let capturedMeetings = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        var versions: [MacBackupTranscriptVersion] = []
        var sources: [(URL, Data)] = []
        var totalBytes = 0
        for entry in entries {
            try cancellation.check()
            guard UUID(uuidString: entry) != nil else { continue }
            let jobURL = root.appendingPathComponent(entry).appendingPathComponent("job.json")
            let bytes = try readBoundedJSON(jobURL, limit: jsonLimit)
            let envelope = try JSONDecoder().decode(ProcessingEnvelope.self, from: bytes)
            guard let state = MacBackupTranscriptVersion.State(rawValue: envelope.state),
                  let meeting = capturedMeetings[envelope.meetingID] else { continue }
            guard envelope.version == 2, envelope.id.uuidString == entry else {
                throw MacBackupError.invalidTranscriptVersion
            }
            let source = try JSONDecoder().decode(ProcessingSource.self, from: bytes)
            for frozen in [source.previous.meeting, source.proposal.meeting] {
                guard frozen.id == meeting.id, frozen.audioFileName == meeting.audioFileName,
                      frozen.audioSHA256 == nil || frozen.audioSHA256 == source.audioSHA256,
                      frozen.audioByteCount == nil || frozen.audioByteCount == source.audioByteCount else {
                    throw MacBackupError.invalidTranscriptVersion
                }
            }
            guard source.proposal.utterances.allSatisfy({ $0.meetingId == meeting.id && $0.speakerId == nil }) else {
                throw MacBackupError.invalidTranscriptVersion
            }
            versions.append(MacBackupTranscriptVersion(
                id: envelope.id, meetingID: meeting.id, createdAt: source.createdAt, state: state,
                sourceAudioSHA256: source.audioSHA256, sourceAudioByteCount: source.audioByteCount,
                title: source.proposal.meeting.title, startedAt: source.proposal.meeting.startedAt,
                durationMs: source.proposal.meeting.durationMs, language: source.language, models: source.models,
                segments: source.proposal.utterances.map {
                    .init(id: $0.id, startMs: $0.startMs, endMs: $0.endMs, text: $0.text,
                          localeIdentifier: $0.localeIdentifier, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
                }
            ))
            totalBytes += bytes.count
            guard totalBytes <= versionsLimit else { throw MacBackupError.invalidTranscriptVersion }
            sources.append((jobURL, bytes))
        }
        try validateTranscriptVersions(versions, meetings: meetings)
        // Processing atomically replaces job.json. Read it again so a state or
        // proposal change while collecting versions cannot be silently mixed in.
        for (url, frozenBytes) in sources {
            try cancellation.check()
            guard try readBoundedJSON(url, limit: jsonLimit) == frozenBytes else {
                throw MacBackupError.invalidTranscriptVersion
            }
        }
        return versions
    }

    private static func validateTranscriptVersions(_ versions: [MacBackupTranscriptVersion], meetings: [Meeting]) throws {
        let capturedMeetings = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        guard versions.count <= 10_000, Set(versions.map(\.id)).count == versions.count else {
            throw MacBackupError.invalidTranscriptVersion
        }
        for version in versions {
            guard let meeting = capturedMeetings[version.meetingID],
                  isSHA256(version.sourceAudioSHA256), version.sourceAudioSHA256 == meeting.audioSHA256,
                  version.sourceAudioByteCount > 0, version.sourceAudioByteCount == meeting.audioByteCount,
                  meeting.audioFileName != nil, version.durationMs >= 0,
                  version.createdAt.timeIntervalSince1970.isFinite, version.startedAt.timeIntervalSince1970.isFinite,
                  !version.language.isEmpty, version.language.count <= 128,
                  !version.models.isEmpty, version.models.count <= 32,
                  !version.segments.isEmpty, Set(version.segments.map(\.id)).count == version.segments.count else {
                throw MacBackupError.invalidTranscriptVersion
            }
            for model in version.models {
                let components = model.repository.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == 2, components.allSatisfy({ isModelIdentifier(String($0)) }),
                      !model.expectedRepositoryRevision.hasPrefix("/"),
                      model.expectedRepositoryRevision.split(separator: "/", omittingEmptySubsequences: false)
                        .allSatisfy({ isModelIdentifier(String($0)) }),
                      !model.expectedRepositoryRevision.isEmpty, model.expectedRepositoryRevision.count <= 256,
                      isSHA256(model.localContentSHA256) else {
                    throw MacBackupError.invalidTranscriptVersion
                }
            }
            for segment in version.segments {
                guard !segment.id.isEmpty, segment.startMs >= 0, segment.endMs >= segment.startMs,
                      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      segment.createdAt.timeIntervalSince1970.isFinite,
                      segment.updatedAt.timeIntervalSince1970.isFinite else {
                    throw MacBackupError.invalidTranscriptVersion
                }
            }
        }
    }

    private static func isModelIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        return !value.isEmpty && value != "." && value != ".." && value.count <= 256
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func readBoundedJSON(_ url: URL, limit: Int) throws -> Data {
        let input = try openRegularFile(url)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: limit + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= limit else { throw MacBackupError.invalidSnapshot }
        return bytes
    }

    private static func verifyPackage(
        at url: URL, cancellation: MacBackupCancellation
    ) throws -> MacBackupManifest {
        try cancellation.check()
        try validatePath(url)
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        let bytes = try readBoundedJSON(manifestURL, limit: jsonLimit)
        let manifest = try JSONDecoder().decode(MacBackupManifest.self, from: bytes)
        guard [1, 2].contains(manifest.formatVersion) else { throw MacBackupError.invalidSnapshot }
        let hasVersions = manifest.formatVersion == 2
        let extraFiles = hasVersions ? 2 : 1
        var rootEntries: Set<String> = ["Audio", "transcript.sqlite", "manifest.json"]
        if hasVersions { rootEntries.insert(versionsPath) }
        guard Set(try fm.contentsOfDirectory(atPath: url.path)) == rootEntries,
              !manifest.schemaMigrations.isEmpty,
              manifest.meetingCount >= 0, manifest.audioCount >= 0, manifest.audioCount <= Int.max - extraFiles,
              manifest.files.count == manifest.audioCount + extraFiles,
              hasVersions ? (manifest.transcriptVersionCount.map { (0...10_000).contains($0) } == true)
                : manifest.transcriptVersionCount == nil,
              manifest.files.filter({ $0.path == versionsPath }).count == (hasVersions ? 1 : 0),
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.filter({ $0.path == "transcript.sqlite" }).count == 1 else {
            throw MacBackupError.invalidSnapshot
        }
        for file in manifest.files {
            guard file.path == "transcript.sqlite" || (hasVersions && file.path == versionsPath) ||
                    (file.path.hasPrefix("Audio/") && isAudioName(String(file.path.dropFirst(6)))),
                  isSHA256(file.sha256), file.byteCount > 0,
                  file.path != versionsPath || file.byteCount <= versionsLimit else {
                throw MacBackupError.invalidSnapshot
            }
            guard try digest(url.appendingPathComponent(file.path), path: file.path, cancellation: cancellation) == file else {
                throw MacBackupError.invalidSnapshot
            }
        }
        let audioURL = url.appendingPathComponent("Audio")
        try validatePath(audioURL)
        try cancellation.check()
        let metadata = try readMetadata(at: url.appendingPathComponent("transcript.sqlite"))
        try cancellation.check()
        let references = try audioReferences(metadata.meetings)
        let expected = references.map {
            MacBackupManifest.File(path: "Audio/" + $0.path, sha256: $0.sha256, byteCount: $0.byteCount)
        }
        guard metadata.meetings.count == manifest.meetingCount,
              metadata.migrations == manifest.schemaMigrations,
              references.count == manifest.audioCount,
              expected == manifest.files.filter({ $0.path.hasPrefix("Audio/") }).sorted(by: { $0.path < $1.path }),
              Set(try fm.contentsOfDirectory(atPath: audioURL.path)) == Set(references.map(\.path)) else {
            throw MacBackupError.invalidSnapshot
        }
        if hasVersions {
            let versionBytes = try readBoundedJSON(url.appendingPathComponent(versionsPath), limit: versionsLimit)
            let versions = try JSONDecoder().decode([MacBackupTranscriptVersion].self, from: versionBytes)
            guard versions.count == manifest.transcriptVersionCount else { throw MacBackupError.invalidSnapshot }
            let originalJSON = try JSONSerialization.jsonObject(with: versionBytes) as? NSArray
            let sanitizedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(versions)) as? NSArray
            guard originalJSON?.isEqual(sanitizedJSON) == true else { throw MacBackupError.invalidSnapshot }
            try validateTranscriptVersions(versions, meetings: metadata.meetings)
        }
        return manifest
    }

    private static func publish(
        stage: URL, destination: URL, context: MacLibraryContext, cancellation: MacBackupCancellation
    ) throws -> URL {
        var outcome: Result<URL, any Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: destination, options: [], error: &coordinationError) { folder in
            outcome = Result {
                try cancellation.check()
                try validateDestination(folder, context: context)
                let fm = FileManager.default
                let identifier = UUID().uuidString
                let partial = folder.appendingPathComponent(".Transcript-partial-" + identifier, isDirectory: true)
                let final = folder.appendingPathComponent(
                    "Transcript-v2-\(Int(Date().timeIntervalSince1970))-\(identifier).transcriptbackup",
                    isDirectory: true
                )
                try fm.createDirectory(at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: partial) }
                try fm.createDirectory(at: partial.appendingPathComponent("Audio"), withIntermediateDirectories: false)
                let manifest = try verifyPackage(at: stage, cancellation: cancellation)
                for path in manifest.files.map(\.path) + ["manifest.json"] {
                    _ = try copyFile(
                        from: stage.appendingPathComponent(path), to: partial.appendingPathComponent(path),
                        path: path, cancellation: cancellation
                    )
                }
                _ = try verifyPackage(at: partial, cancellation: cancellation)
                try cancellation.check()
                try validateDestination(folder, context: context)
                // Same-volume rename is the commit point. No final snapshot name is
                // visible before all bytes and the captured database verify.
                guard renamex_np(partial.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return final
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw MacBackupError.unavailableFolder }
        return try outcome.get()
    }

    private static func validatePath(_ url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0),
              url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw MacBackupError.unsafePath(url.path)
        }
        var component = url.standardizedFileURL
        while component.path != "/" {
            var status = stat()
            if lstat(component.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFLNK {
                throw MacBackupError.unsafePath(url.path)
            }
            component.deleteLastPathComponent()
        }
    }

    private static func openRegularFile(_ url: URL) throws -> FileHandle {
        let fd = try openWithoutFollowingLinks(url, flags: O_RDONLY | O_NONBLOCK)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw MacBackupError.unsafePath(url.path)
        }
        return handle
    }

    private static func openWithoutFollowingLinks(_ url: URL, flags: Int32) throws -> Int32 {
        try validatePath(url)
        let components = url.standardizedFileURL.pathComponents.dropFirst()
        guard let name = components.last else { throw MacBackupError.unsafePath(url.path) }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        // O_NOFOLLOW on the leaf alone does not protect against an ancestor
        // directory being replaced with a symlink between validation and open.
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw MacBackupError.unsafePath(url.path) }
            close(parent)
            parent = next
        }
        let fd = openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    private static func digest(
        _ url: URL, path: String, cancellation: MacBackupCancellation
    ) throws -> MacBackupManifest.File {
        try stream(from: url, to: nil, path: path, cancellation: cancellation)
    }

    private static func copyFile(
        from source: URL, to destination: URL, path: String, cancellation: MacBackupCancellation
    ) throws -> MacBackupManifest.File {
        try stream(from: source, to: destination, path: path, cancellation: cancellation)
    }

    private static func stream(
        from source: URL, to destination: URL?, path: String, cancellation: MacBackupCancellation
    ) throws -> MacBackupManifest.File {
        try cancellation.check()
        let input = try openRegularFile(source)
        defer { try? input.close() }
        var output: FileHandle?
        if let destination {
            let fd = try openWithoutFollowingLinks(destination, flags: O_WRONLY | O_CREAT | O_EXCL)
            output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var hash = IncrementalSHA256()
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try cancellation.check()
            hash.update(data)
            try output?.write(contentsOf: data)
        }
        try cancellation.check()
        try output?.synchronize()
        return MacBackupManifest.File(path: path, sha256: hash.finalize(), byteCount: hash.byteCount)
    }

    private static func isAudioName(_ name: String) -> Bool {
        guard name.hasSuffix(".m4a") else { return false }
        let stem = name.dropLast(4)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return !stem.isEmpty && stem.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
