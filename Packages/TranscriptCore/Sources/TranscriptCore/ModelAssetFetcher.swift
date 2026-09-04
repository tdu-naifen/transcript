import CryptoKit
import Foundation

struct ModelAssetSource: Sendable {
    let repository: String
    let revision: String
    let prefix: String
    let includedRoots: [String]

    func safeRelativePath(for manifestPath: String) -> String? {
        let relative: String
        if !prefix.isEmpty, manifestPath.hasPrefix(prefix + "/") {
            relative = String(manifestPath.dropFirst(prefix.count + 1))
        } else {
            relative = manifestPath
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !components.contains(".."),
              !components.contains("")
        else { return nil }
        return relative
    }
}

protocol ModelAssetFetching: Sendable {
    func byteCount(source: ModelAssetSource) async throws -> Int64

    func fetch(
        source: ModelAssetSource,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws
}

actor HuggingFaceModelFetcher: ModelAssetFetching {
    enum Failure: LocalizedError {
        case invalidManifest(String)
        case invalidPath(String)
        case http(Int, String)
        case sizeMismatch(String, expected: Int64, actual: Int64)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest(let detail): "Invalid Hugging Face model manifest: \(detail)"
            case .invalidPath(let path): "Unsafe model path in manifest: \(path)"
            case .http(let status, let path): "Hugging Face returned HTTP \(status) for \(path)"
            case .sizeMismatch(let path, let expected, let actual):
                "Downloaded size mismatch for \(path): expected \(expected), got \(actual)"
            case .checksumMismatch(let path): "Downloaded checksum mismatch for \(path)"
            }
        }
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String?
            let size: Int64?
        }

        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?

        var byteCount: Int64 { lfs?.size ?? size ?? 0 }
        var sha256: String? { lfs?.oid }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func byteCount(source: ModelAssetSource) async throws -> Int64 {
        let entries = try await manifest(for: source)
        guard !entries.isEmpty else { throw Failure.invalidManifest("no files matched \(source.prefix)") }
        let total = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total > 0 else { throw Failure.invalidManifest("all matched files have zero size") }
        return total
    }

    func fetch(
        source: ModelAssetSource,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws {
        let entries = try await manifest(for: source)
        guard !entries.isEmpty else { throw Failure.invalidManifest("no files matched \(source.prefix)") }
        let total = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total > 0 else { throw Failure.invalidManifest("all matched files have zero size") }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed: Int64 = 0
        await progress(0, total)
        for entry in entries {
            try Task.checkCancellation()
            let relativePath = try relativePath(for: entry.path, source: source)
            let fileURL = destination.appending(path: relativePath)
            let existing = validByteCount(at: fileURL, expected: entry.byteCount, sha256: entry.sha256)
            if existing == entry.byteCount {
                completed += entry.byteCount
                await progress(completed, total)
                continue
            }
            try await download(
                entry: entry,
                source: source,
                to: fileURL,
                completedBeforeFile: completed,
                total: total,
                progress: progress
            )
            completed += entry.byteCount
            await progress(completed, total)
        }
    }

    private func manifest(for source: ModelAssetSource) async throws -> [TreeEntry] {
        let suffix = source.prefix.isEmpty ? "" : "/\(escapedPath(source.prefix))"
        let url = URL(string: "https://huggingface.co/api/models/\(source.repository)/tree/\(source.revision)\(suffix)?recursive=1&expand=0")!
        let (data, response) = try await session.data(from: url)
        try validate(response: response, path: source.prefix.isEmpty ? source.repository : source.prefix)
        let decoded = try JSONDecoder().decode([TreeEntry].self, from: data)
        return decoded.filter { entry in
            guard entry.type == "file", entry.byteCount > 0 else { return false }
            guard !source.includedRoots.isEmpty else { return true }
            let relative = relativePathUnchecked(entry.path, prefix: source.prefix)
            return source.includedRoots.contains { relative == $0 || relative.hasPrefix($0 + "/") }
        }.sorted { $0.path < $1.path }
    }

    private func download(
        entry: TreeEntry,
        source: ModelAssetSource,
        to destination: URL,
        completedBeforeFile: Int64,
        total: Int64,
        progress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        var offset = fileSize(at: partial)
        if offset > entry.byteCount {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }

        var request = URLRequest(url: URL(string: "https://huggingface.co/\(source.repository)/resolve/\(source.revision)/\(escapedPath(entry.path))")!)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response: response, path: entry.path, allowedStatuses: offset > 0 ? [200, 206] : [200])
        if offset > 0, (response as? HTTPURLResponse)?.statusCode == 200 {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }

        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var written = offset
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await progress(completedBeforeFile + written, total)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            await progress(completedBeforeFile + written, total)
        }
        try handle.synchronize()

        guard written == entry.byteCount else {
            throw Failure.sizeMismatch(entry.path, expected: entry.byteCount, actual: written)
        }
        if let expected = entry.sha256, try sha256(of: partial) != expected {
            throw Failure.checksumMismatch(entry.path)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func relativePath(for path: String, source: ModelAssetSource) throws -> String {
        guard let relative = source.safeRelativePath(for: path) else { throw Failure.invalidPath(path) }
        return relative
    }

    private func relativePathUnchecked(_ path: String, prefix: String) -> String {
        guard !prefix.isEmpty, path.hasPrefix(prefix + "/") else { return path }
        return String(path.dropFirst(prefix.count + 1))
    }

    private func validate(response: URLResponse, path: String, allowedStatuses: Set<Int> = [200]) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidManifest("non-HTTP response") }
        guard allowedStatuses.contains(http.statusCode) else { throw Failure.http(http.statusCode, path) }
    }

    private func validByteCount(at url: URL, expected: Int64, sha256 expectedHash: String?) -> Int64 {
        let size = fileSize(at: url)
        guard size == expected else { return 0 }
        guard let expectedHash else { return size }
        return ((try? sha256(of: url)) == expectedHash) ? size : 0
    }

    private func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func escapedPath(_ path: String) -> String {
        path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }
}