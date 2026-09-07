import CoreML
import Foundation
import FluidAudio

public enum DynamicSpeakerModelError: Error, LocalizedError {
    case invalidReceipt, invalidFile(String), installationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidReceipt: "Dynamic speaker model receipt is invalid. Update the app and retry."
        case .invalidFile(let path): "Dynamic speaker models are missing or damaged (\(path)). Reinstall and retry speaker analysis."
        case .installationFailed(let reason): "Could not install dynamic speaker models: \(reason). Retry speaker analysis when online."
        }
    }
}

/// Exact public community-1 assets; never calls the SDK's unpinned ModelHub loader.
public actor DynamicSpeakerModelStore {
    public static let shared = DynamicSpeakerModelStore()
    public static let revision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
    public static let overrideEnvironmentKey = "TRANSCRIPT_DYNAMIC_SPEAKER_MODEL_ROOT"
    private var installation: Task<URL, any Error>?
    private let destination: URL?

    struct Receipt: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int
            let sha256: String
        }
        let repository: String
        let revision: String
        let license: String
        let modelFileCount: Int
        let files: [File]
    }

    public init(destination: URL? = nil) { self.destination = destination }

    static func receipt() throws -> Receipt {
        guard let url = Bundle.module.url(forResource: "dynamic-speaker-model-manifest", withExtension: "json") else {
            throw DynamicSpeakerModelError.invalidReceipt
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard receipt.repository == "FluidInference/speaker-diarization-coreml",
              receipt.revision == revision, receipt.license == "CC-BY-4.0",
              receipt.modelFileCount == 21, receipt.files.count == 22,
              Set(receipt.files.map(\.path)).count == 22,
              receipt.files.allSatisfy({
                  !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..")
                      && $0.size > 0 && $0.sha256.count == 64
              }) else { throw DynamicSpeakerModelError.invalidReceipt }
        return receipt
    }

    public static func verify(directory: URL) throws {
        let receipt = try receipt()
        for file in receipt.files where file.path != "README.md" {
            try Task.checkCancellation()
            let url = directory.appending(path: file.path)
            var ancestor = url
            while ancestor.path.count >= directory.path.count {
                guard (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
                    throw DynamicSpeakerModelError.invalidFile(file.path)
                }
                ancestor.deleteLastPathComponent()
            }
            guard let hash = try? IncrementalSHA256.hashFile(at: url),
                  hash.sha256 == file.sha256,
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.size
            else { throw DynamicSpeakerModelError.invalidFile(file.path) }
        }
    }

    public func ensureInstalled() async throws -> URL {
        if let installation {
            let result = try await installation.value
            try Task.checkCancellation()
            return result
        }
        let destination = self.destination
        let task = Task<URL, any Error> {
            if destination == nil,
               let override = ProcessInfo.processInfo.environment[Self.overrideEnvironmentKey], !override.isEmpty {
                let url = URL(filePath: override, directoryHint: .isDirectory)
                try Self.verify(directory: url)
                return url
            }
            let root: URL
            if let destination { root = destination } else {
                root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
                    .appending(path: "Models/dynamic-speakers/\(Self.revision)", directoryHint: .isDirectory)
            }
            if (try? Self.verify(directory: root)) != nil { return root }
            let receipt = try Self.receipt()
            let staging = root.deletingLastPathComponent().appending(path: ".install-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 120
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                for file in receipt.files where file.path != "README.md" {
                    try Task.checkCancellation()
                    let remote = URL(string: "https://huggingface.co/\(receipt.repository)/resolve/\(receipt.revision)/\(file.path)")!
                    let (stream, response) = try await session.bytes(from: remote)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          response.expectedContentLength == -1 || response.expectedContentLength == file.size else {
                        throw DynamicSpeakerModelError.invalidFile(file.path)
                    }
                    var data = Data()
                    data.reserveCapacity(file.size)
                    for try await byte in stream {
                        try Task.checkCancellation()
                        guard data.count < file.size else { throw DynamicSpeakerModelError.invalidFile(file.path) }
                        data.append(byte)
                    }
                    guard data.count == file.size else { throw DynamicSpeakerModelError.invalidFile(file.path) }
                    let target = staging.appending(path: file.path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                }
                try Self.verify(directory: staging)
                try Task.checkCancellation()
                // Receipt is shipped with the app; staging is never considered installed.
                if FileManager.default.fileExists(atPath: root.path) {
                    _ = try FileManager.default.replaceItemAt(root, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: root)
                }
                try Self.verify(directory: root)
                return root
            } catch is CancellationError { throw CancellationError() }
            catch { throw DynamicSpeakerModelError.installationFailed(error.localizedDescription) }
        }
        installation = task
        defer { installation = nil }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    static func loadVerified(directory: URL, cpuOnly: Bool = false) throws -> OfflineDiarizerModels {
        try verify(directory: directory)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = cpuOnly ? .cpuOnly : .all
        let start = Date()
        let segmentation = try MLModel(contentsOf: directory.appending(path: "Segmentation.mlmodelc"), configuration: configuration)
        let fbank = try MLModel(contentsOf: directory.appending(path: "FBank.mlmodelc"), configuration: configuration)
        let embedding = try MLModel(contentsOf: directory.appending(path: "Embedding.mlmodelc"), configuration: configuration)
        let plda = try MLModel(contentsOf: directory.appending(path: "PldaRho.mlmodelc"), configuration: configuration)
        let data = try Data(contentsOf: directory.appending(path: "plda-parameters.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let info = tensors["psi"] as? [String: Any],
              let base64 = info["data_base64"] as? String,
              let bytes = Data(base64Encoded: base64), bytes.count == 128 * 4
        else { throw DynamicSpeakerModelError.invalidReceipt }
        let psi = stride(from: 0, to: bytes.count, by: 4).map { offset in
            let bits = bytes[offset..<(offset + 4)].enumerated().reduce(UInt32.zero) { $0 | UInt32($1.element) << ($1.offset * 8) }
            return Double(Float(bitPattern: bits))
        }
        guard psi.allSatisfy(\.isFinite) else { throw DynamicSpeakerModelError.invalidReceipt }
        return OfflineDiarizerModels(segmentationModel: segmentation, fbankModel: fbank, embeddingModel: embedding,
                                     pldaRhoModel: plda, pldaPsi: psi, compilationDuration: Date().timeIntervalSince(start))
    }
}

extension ASRModelDownloader {
    public func ensureDynamicSpeakersInstalled() async throws -> URL {
        try await DynamicSpeakerModelStore.shared.ensureInstalled()
    }
}
