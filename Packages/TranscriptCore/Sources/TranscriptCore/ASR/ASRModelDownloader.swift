import Foundation

/// A published (family, tier) pair, e.g. `multilingual/2240ms`.
public struct ASRModelVariant: Sendable, Hashable, Codable {
    public let family: String
    public let tierMilliseconds: Int

    public init(family: String, tierMilliseconds: Int) {
        self.family = family
        self.tierMilliseconds = tierMilliseconds
    }

    public static let multilingual2240ms = ASRModelVariant(family: "multilingual", tierMilliseconds: 2240)

    public var relativePath: String { "\(family)/\(tierMilliseconds)ms" }
}

/// An on-disk model directory `StreamingNemotronMultilingualAsrManager.loadModels(from:)`
/// can load as-is. Existence of the directory says nothing about completeness, so ask
/// ``installState`` rather than `FileManager`.
public struct ASRModelBundle: Sendable, Hashable {
    public let variant: ASRModelVariant
    public let directory: URL

    public init(variant: ASRModelVariant, directory: URL) {
        self.variant = variant
        self.directory = directory
    }

    /// Exactly what FluidAudio's `loadModels(from:)` requires. `preprocessor.mlmodelc`
    /// is not in this list — FluidAudio computes mel natively in Swift and ignores it.
    static let requiredNames = [
        "encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc",
        "decoder_joint.mlmodelc", "metadata.json", "tokenizer.json"
    ]

    public enum InstallState: Sendable, Hashable {
        case absent
        case incomplete(missing: [String])
        case installed
    }

    public var installState: InstallState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return .absent }
        let missing = Self.requiredNames.filter { !fm.fileExists(atPath: directory.appending(path: $0).path) }
        if missing.isEmpty { return .installed }
        return missing.count == Self.requiredNames.count ? .absent : .incomplete(missing: missing)
    }

    public var isInstalled: Bool { installState == .installed }

    /// Bytes actually on disk, for a "1.2 GB used" style UI row.
    public var byteCount: Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

/// Resolves where models live on disk. Never touches the network — the product's
/// "No Internet Required" claim means the bundle must already be local, whether
/// bundled with the app or placed by a developer via ``overrideEnvironmentKey``.
public enum ASRModelStore {
    /// Set to a checkout's `Models/nemotron-asr` to run the benchmark without moving
    /// files into Application Support first.
    public static let overrideEnvironmentKey = "TRANSCRIPT_ASR_MODEL_ROOT"

    public static var applicationSupportRoot: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        return base.appending(path: "Models/nemotron-asr", directoryHint: .isDirectory)
    }

    /// Search order: explicit override, app bundle (dev builds), Application Support.
    public static func searchRoots(bundle: Bundle = .main) -> [URL] {
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment[overrideEnvironmentKey], !override.isEmpty {
            roots.append(URL(filePath: override, directoryHint: .isDirectory))
        }
        if let resource = bundle.resourceURL {
            roots.append(resource.appending(path: "nemotron-asr", directoryHint: .isDirectory))
        }
        roots.append(applicationSupportRoot)
        return roots
    }

    /// The installed bundle, or the Application Support location it *should* occupy
    /// so a caller can show a "put the model here" message pointing at a real path.
    public static func bundle(
        for variant: ASRModelVariant = .multilingual2240ms,
        searchRoots: [URL] = ASRModelStore.searchRoots()
    ) -> ASRModelBundle {
        var fallback: ASRModelBundle?
        for root in searchRoots {
            let candidate = ASRModelBundle(
                variant: variant,
                directory: root.appending(path: variant.relativePath, directoryHint: .isDirectory)
            )
            if candidate.isInstalled { return candidate }
            if fallback == nil { fallback = candidate }
        }
        return fallback ?? ASRModelBundle(
            variant: variant,
            directory: applicationSupportRoot.appending(path: variant.relativePath, directoryHint: .isDirectory)
        )
    }

    /// Where a local copy must land, ignoring read-only search roots.
    public static func installDestination(for variant: ASRModelVariant = .multilingual2240ms) -> ASRModelBundle {
        ASRModelBundle(
            variant: variant,
            directory: applicationSupportRoot.appending(path: variant.relativePath, directoryHint: .isDirectory)
        )
    }
}

/// Verification state of the local model bundle, for the UI to render directly.
public enum ASRModelDownloadState: Sendable, Hashable {
    case notInstalled
    /// Kept for source compatibility with call sites written against the previous
    /// (network-fetching) downloader. This build never produces it — there is no
    /// transfer to report progress for.
    case downloading(completedBytes: Int64, totalBytes: Int64)
    case verifying
    case installed(byteCount: Int64)
    case failed(String)

    public var fraction: Double {
        guard case .downloading(let completed, let total) = self, total > 0 else {
            if case .installed = self { return 1 }
            return 0
        }
        return min(1, Double(completed) / Double(total))
    }
}

/// Verifies the FluidAudio-compatible model bundle is present locally.
///
/// 🔴 OFFLINE ONLY: this never calls the network. Earlier revisions of this file
/// fetched the CoreML bundle from Hugging Face; that path is gone. The model is
/// expected to already be on disk (dev override, or bundled with the app once
/// packaging lands — PLAN §7 `1c`), and this actor only checks completeness.
public actor ASRModelDownloader {
    public struct Configuration: Sendable {
        public var variant: ASRModelVariant
        public var destination: URL

        public init(
            variant: ASRModelVariant = .multilingual2240ms,
            destination: URL = ASRModelStore.installDestination().directory
        ) {
            self.variant = variant
            self.destination = destination
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notInstalled(URL)

        public var description: String {
            switch self {
            case .notInstalled(let url):
                "model not found at \(url.path) — this build never downloads it; place the "
                    + "FluidAudio-compatible bundle there"
            }
        }
    }

    private let configuration: Configuration
    private var continuations: [UUID: AsyncStream<ASRModelDownloadState>.Continuation] = [:]
    private var currentState: ASRModelDownloadState

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.currentState = Self.state(for: ASRModelBundle(
            variant: configuration.variant,
            directory: configuration.destination
        ))
    }

    public var state: ASRModelDownloadState { currentState }

    public nonisolated var bundle: ASRModelBundle {
        ASRModelBundle(variant: configuration.variant, directory: configuration.destination)
    }

    /// Live state. Each subscriber gets the current value immediately.
    public func states() -> AsyncStream<ASRModelDownloadState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ASRModelDownloadState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuations[id] = continuation
        return stream
    }

    /// Re-checks the local directory. No network call — see the type doc.
    @discardableResult
    public func ensureInstalled() async throws -> ASRModelBundle {
        publish(.verifying)
        let resolved = bundle
        guard resolved.isInstalled else {
            let failure = Failure.notInstalled(resolved.directory)
            publish(.failed(failure.description))
            throw failure
        }
        publish(.installed(byteCount: resolved.byteCount))
        return resolved
    }

    /// Nothing is ever in flight, so this only re-publishes the current state.
    public func cancel() {
        publish(Self.state(for: bundle))
    }

    /// Frees the local copy at ``Configuration/destination``.
    public func remove() throws {
        try? FileManager.default.removeItem(at: configuration.destination)
        publish(.notInstalled)
    }

    private func removeSubscriber(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish(_ state: ASRModelDownloadState) {
        currentState = state
        for continuation in continuations.values { continuation.yield(state) }
    }

    private static func state(for bundle: ASRModelBundle) -> ASRModelDownloadState {
        switch bundle.installState {
        case .absent: .notInstalled
        case .incomplete(let missing): .failed("missing \(missing.joined(separator: ", "))")
        case .installed: .installed(byteCount: bundle.byteCount)
        }
    }
}

