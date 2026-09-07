import CryptoKit
import Foundation

enum MacModelArtifactVerifier {
    struct Entry: Decodable, Sendable {
        struct LFS: Decodable, Sendable {
            let oid: String
            let size: Int64
        }
        let type: String
        let path: String
        let size: Int64?
        let oid: String?
        let lfs: LFS?
    }

    enum Failure: LocalizedError {
        case invalidManifest
        case invalidFile(String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest: processingText("Could not validate the pinned model manifest. Check your connection and retry.")
            case .invalidFile(let path):
                "\(processingText("Model integrity validation failed. The file does not match the pinned revision:")) \(path)"
            }
        }
    }

    static func source(for category: MacModelCategory) -> (card: MacModelCard, prefix: String, roots: [String]) {
        let card = MacModelCard.builtins.first { $0.category == category }!
        switch category {
        case .asr:
            return (card, "multilingual/2240ms",
                    ["encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc", "decoder_joint.mlmodelc",
                     "metadata.json", "tokenizer.json"])
        case .diarization:
            return (card, "v3/palettized/Sortformer_v2.1.mlmodelc", [])
        case .speakerEmbedding:
            return (card, "", ["CamPlusPreprocessor.mlmodelc", "CamPlusPlus.mlmodelc"])
        }
    }

    static func verify(category: MacModelCategory, at directory: URL) async throws {
        let source = source(for: category)
        let suffix = source.prefix.isEmpty ? "" : "/\(source.prefix)"
        let url = URL(string: "https://huggingface.co/api/models/\(source.card.repository)/tree/\(source.card.revision)\(suffix)?recursive=1&expand=0")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.url?.host == "huggingface.co" else {
            throw Failure.invalidManifest
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2 * 1_024 * 1_024 else { throw Failure.invalidManifest }
            data.append(byte)
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        try verify(entries: entries, prefix: source.prefix, roots: source.roots, at: directory)
    }

    static func verify(entries: [Entry], prefix: String, roots: [String], at directory: URL) throws {
        var count = 0
        for entry in entries where entry.type == "file" {
            try Task.checkCancellation()
            let relative: String
            if prefix.isEmpty {
                relative = entry.path
            } else {
                guard entry.path.hasPrefix(prefix + "/") else { throw Failure.invalidManifest }
                relative = String(entry.path.dropFirst(prefix.count + 1))
            }
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, !components.contains(""), !components.contains(".."),
                  !components.contains(".") else { throw Failure.invalidManifest }
            if !roots.isEmpty, !roots.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                continue
            }
            let file = directory.appendingPathComponent(relative)
            do {
                try verifyFile(entry, at: file, relative: relative, directory: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.invalidFile(relative)
            }
            count += 1
        }
        guard count > 0 else { throw Failure.invalidManifest }
    }

    private static func verifyFile(_ entry: Entry, at file: URL, relative: String, directory: URL) throws {
            let expectedSize = entry.lfs?.size ?? entry.size ?? 0
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard expectedSize > 0, values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? 0) == expectedSize,
                  file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
            else { throw Failure.invalidFile(relative) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var sha256 = SHA256()
            var gitBlob = Insecure.SHA1()
            gitBlob.update(data: Data("blob \(expectedSize)\0".utf8))
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                sha256.update(data: chunk)
                gitBlob.update(data: chunk)
            }
            let actual: String
            let expected: String?
            if let lfs = entry.lfs {
                actual = sha256.finalize().map { String(format: "%02x", $0) }.joined()
                expected = lfs.oid
            } else {
                actual = gitBlob.finalize().map { String(format: "%02x", $0) }.joined()
                expected = entry.oid
            }
            guard actual == expected else { throw Failure.invalidFile(relative) }
    }
}
