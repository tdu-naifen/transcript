import Foundation
import FluidAudio

enum ModelAssetValidation {
    static func isValidCompiledModel(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              isNonemptyFile(at: url.appending(path: "coremldata.bin"))
        else { return false }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        return !walker.contains { ($0 as? URL)?.pathExtension == "partial" }
    }

    static func isValidJSON(at url: URL) -> Bool {
        guard isNonemptyFile(at: url), let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    static func isNonemptyFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}

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
        let missing = Self.requiredNames.filter { name in
            let url = directory.appending(path: name)
            if name.hasSuffix(".mlmodelc") { return !ModelAssetValidation.isValidCompiledModel(at: url) }
            if name.hasSuffix(".json") { return !ModelAssetValidation.isValidJSON(at: url) }
            return !ModelAssetValidation.isNonemptyFile(at: url)
        }
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

/// Resolves existing local models before the downloader chooses Application Support.
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

public struct RecordingModelInstallation: Sendable, Hashable {
    public let asr: ASRModelBundle
    public let sortformerModel: URL
    public let campPlusDirectory: URL

    public var byteCount: Int64 {
        asr.byteCount
            + Self.byteCount(at: sortformerModel)
            + Self.byteCount(at: campPlusDirectory)
    }

    private static func byteCount(at directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        return walker.reduce(into: Int64(0)) { total, item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }
}

/// Installs the on-device recording models from their published Hugging Face repos.
public actor ASRModelDownloader {
    public struct Configuration: Sendable {
        public var variant: ASRModelVariant
        public var destination: URL
        public var sortformerDestination: URL
        public var campPlusDestination: URL
        let managesDestination: Bool
        let managesSortformerDestination: Bool
        let managesCampPlusDestination: Bool

        public init(
            variant: ASRModelVariant = .multilingual2240ms,
            destination: URL? = nil,
            sortformerDestination: URL? = nil,
            campPlusDestination: URL? = nil
        ) {
            self.variant = variant
            let localASR = ASRModelStore.bundle(for: variant)
            self.destination = destination ?? (localASR.isInstalled
                ? localASR.directory
                : ASRModelStore.installDestination(for: variant).directory)
            self.managesDestination = destination != nil || !localASR.isInstalled
            let localSortformer = DiarizationModelStore.sortformerMainModelPath()
            self.sortformerDestination = sortformerDestination
                ?? (DiarizationModelStore.isSortformerInstalled(at: localSortformer)
                    ? localSortformer
                    : DiarizationModelStore.sortformerMainModelPath(searchRoots: []))
            self.managesSortformerDestination = sortformerDestination != nil
                || !DiarizationModelStore.isSortformerInstalled(at: localSortformer)
            let localCampPlus = DiarizationModelStore.campPlusDirectory()
            self.campPlusDestination = campPlusDestination
                ?? (DiarizationModelStore.isCampPlusInstalled(at: localCampPlus)
                    ? localCampPlus
                    : DiarizationModelStore.campPlusApplicationSupportRoot)
            self.managesCampPlusDestination = campPlusDestination != nil
                || !DiarizationModelStore.isCampPlusInstalled(at: localCampPlus)
        }
    }

    public static let nemotronRevision = "1a41b75758b0337ff67db7d5408280aaaf23074e"
    public static let sortformerRevision = "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"
    public static let campPlusRevision = "daa02e7cc1b98e4f3f6fec94db9d91f3b0cf4120"

    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case invalidDownload(String, URL)

        public var description: String {
            switch self {
            case .invalidDownload(let model, let url):
                "Downloaded \(model) assets are incomplete or corrupt at \(url.path)"
            }
        }

        public var errorDescription: String? { description }
    }

    private let configuration: Configuration
    private let fetcher: any ModelAssetFetching
    private var continuations: [UUID: AsyncStream<ASRModelDownloadState>.Continuation] = [:]
    private var currentState: ASRModelDownloadState
    private var activeASRTask: Task<ASRModelBundle, any Error>?
    private var activeRecordingTask: Task<RecordingModelInstallation, any Error>?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.fetcher = HuggingFaceModelFetcher()
        self.currentState = Self.recordingState(for: configuration)
    }

    init(configuration: Configuration, fetcher: any ModelAssetFetching) {
        self.configuration = configuration
        self.fetcher = fetcher
        self.currentState = Self.recordingState(for: configuration)
    }

    public var state: ASRModelDownloadState { currentState }

    public nonisolated var bundle: ASRModelBundle {
        ASRModelBundle(variant: configuration.variant, directory: configuration.destination)
    }

    /// Live state. Each subscriber gets the current value immediately.
    public func states() -> AsyncStream<ASRModelDownloadState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ASRModelDownloadState>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuations[id] = continuation
        return stream
    }

    @discardableResult
    public func ensureInstalled() async throws -> ASRModelBundle {
        let resolved = bundle
        if resolved.isInstalled {
            publish(.installed(byteCount: resolved.byteCount))
            return resolved
        }
        if let activeRecordingTask { return try await activeRecordingTask.value.asr }
        if let activeASRTask { return try await activeASRTask.value }

        let task = Task { try await self.installASR() }
        activeASRTask = task
        do {
            let installed = try await task.value
            activeASRTask = nil
            return installed
        } catch is CancellationError {
            activeASRTask = nil
            publish(Self.state(for: resolved))
            throw CancellationError()
        } catch {
            activeASRTask = nil
            publish(.failed(error.localizedDescription))
            throw error
        }
    }

    public func cancel() {
        activeASRTask?.cancel()
        activeRecordingTask?.cancel()
    }

    public func ensureRecordingModelsInstalled() async throws -> RecordingModelInstallation {
        if let installed = installedRecordingModels() {
            publish(.installed(byteCount: installed.byteCount))
            return installed
        }
        if let activeRecordingTask { return try await activeRecordingTask.value }

        let task = Task { try await self.installRecordingModels() }
        activeRecordingTask = task
        do {
            let installed = try await task.value
            activeRecordingTask = nil
            return installed
        } catch is CancellationError {
            activeRecordingTask = nil
            publish(Self.recordingState(for: configuration))
            throw CancellationError()
        } catch {
            activeRecordingTask = nil
            publish(.failed(error.localizedDescription))
            throw error
        }
    }

    public func ensureSortformerInstalled() async throws -> URL {
        let destination = configuration.sortformerDestination
        if DiarizationModelStore.isSortformerInstalled(at: destination) { return destination }
        try await install(
            name: "Sortformer palettized",
            source: sortformerSource,
            destination: destination,
            isValid: DiarizationModelStore.isSortformerInstalled(at:),
            progress: { completed, total in
                await self.publish(.downloading(completedBytes: completed, totalBytes: total))
            },
            publishesVerification: true
        )
        return destination
    }

    public func ensureCampPlusInstalled() async throws -> URL {
        let destination = configuration.campPlusDestination
        if DiarizationModelStore.isCampPlusInstalled(at: destination) { return destination }
        try await install(
            name: "CAM++",
            source: campPlusSource,
            destination: destination,
            isValid: DiarizationModelStore.isCampPlusInstalled(at:),
            progress: { completed, total in
                await self.publish(.downloading(completedBytes: completed, totalBytes: total))
            },
            publishesVerification: true
        )
        return destination
    }

    /// Frees the local copy at ``Configuration/destination``.
    public func remove() async throws {
        activeASRTask?.cancel()
        activeRecordingTask?.cancel()
        _ = try? await activeASRTask?.value
        _ = try? await activeRecordingTask?.value
        activeASRTask = nil
        activeRecordingTask = nil
        for destination in managedRecordingDestinations {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: stagingURL(for: destination))
        }
        publish(.notInstalled)
    }

    private func installASR() async throws -> ASRModelBundle {
        let resolved = bundle
        try await install(
            name: "Nemotron multilingual \(configuration.variant.tierMilliseconds)ms",
            source: asrSource,
            destination: resolved.directory,
            isValid: { ASRModelBundle(variant: self.configuration.variant, directory: $0).isInstalled },
            progress: { completed, total in
                await self.publish(.downloading(completedBytes: completed, totalBytes: total))
            },
            publishesVerification: true
        )
        publish(.installed(byteCount: resolved.byteCount))
        return resolved
    }

    private func installRecordingModels() async throws -> RecordingModelInstallation {
        let asrInstalled = bundle.isInstalled
        let sortformerInstalled = DiarizationModelStore.isSortformerInstalled(
            at: configuration.sortformerDestination)
        let campPlusInstalled = DiarizationModelStore.isCampPlusInstalled(
            at: configuration.campPlusDestination)

        let asrBytes = asrInstalled ? 0 : try await fetcher.byteCount(source: asrSource)
        let sortformerBytes = sortformerInstalled ? 0 : try await fetcher.byteCount(source: sortformerSource)
        let campPlusBytes = campPlusInstalled ? 0 : try await fetcher.byteCount(source: campPlusSource)
        let totalBytes = asrBytes + sortformerBytes + campPlusBytes
        publish(.downloading(completedBytes: 0, totalBytes: totalBytes))

        var completedBytes: Int64 = 0
        if !asrInstalled {
            let offset = completedBytes
            try await install(
                name: "Nemotron multilingual \(configuration.variant.tierMilliseconds)ms",
                source: asrSource,
                destination: configuration.destination,
                isValid: { ASRModelBundle(variant: self.configuration.variant, directory: $0).isInstalled },
                progress: { completed, _ in
                    await self.publish(.downloading(
                        completedBytes: offset + completed, totalBytes: totalBytes))
                },
                publishesVerification: false
            )
            completedBytes += asrBytes
        }
        if !sortformerInstalled {
            let offset = completedBytes
            try await install(
                name: "Sortformer palettized",
                source: sortformerSource,
                destination: configuration.sortformerDestination,
                isValid: DiarizationModelStore.isSortformerInstalled(at:),
                progress: { completed, _ in
                    await self.publish(.downloading(
                        completedBytes: offset + completed, totalBytes: totalBytes))
                },
                publishesVerification: false
            )
            completedBytes += sortformerBytes
        }
        if !campPlusInstalled {
            let offset = completedBytes
            try await install(
                name: "CAM++",
                source: campPlusSource,
                destination: configuration.campPlusDestination,
                isValid: DiarizationModelStore.isCampPlusInstalled(at:),
                progress: { completed, _ in
                    await self.publish(.downloading(
                        completedBytes: offset + completed, totalBytes: totalBytes))
                },
                publishesVerification: false
            )
        }

        publish(.verifying)
        guard let installed = installedRecordingModels() else {
            throw Failure.invalidDownload("recording models", configuration.destination)
        }
        publish(.installed(byteCount: installed.byteCount))
        return installed
    }

    private func install(
        name: String,
        source: ModelAssetSource,
        destination: URL,
        isValid: @escaping @Sendable (URL) -> Bool,
        progress: @escaping @Sendable (Int64, Int64) async -> Void,
        publishesVerification: Bool
    ) async throws {
        let staging = stagingURL(for: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await fetcher.fetch(source: source, to: staging, progress: progress)
        try Task.checkCancellation()
        if publishesVerification { publish(.verifying) }
        guard isValid(staging) else { throw Failure.invalidDownload(name, staging) }
        try atomicallyPublish(staging: staging, destination: destination)
    }

    private func atomicallyPublish(staging: URL, destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: staging, to: destination)
            return
        }
        let backup = URL(filePath: destination.path + ".replaced-\(UUID().uuidString)")
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: staging, to: destination)
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.moveItem(at: backup, to: destination)
            throw error
        }
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

    private var asrSource: ModelAssetSource {
        ModelAssetSource(
            repository: Repo.nemotronMultilingual.remotePath,
            revision: Self.nemotronRevision,
            prefix: configuration.variant.relativePath,
            includedRoots: ASRModelBundle.requiredNames
        )
    }

    private var sortformerSource: ModelAssetSource {
        let relative = ModelNames.Sortformer.Variant.fastV2_1.fileName(precision: .palettized)
        return ModelAssetSource(
            repository: Repo.sortformer.remotePath,
            revision: Self.sortformerRevision,
            prefix: relative,
            includedRoots: []
        )
    }

    private var campPlusSource: ModelAssetSource {
        ModelAssetSource(
            repository: Repo.campPlus.remotePath,
            revision: Self.campPlusRevision,
            prefix: "",
            includedRoots: [ModelNames.CampPlus.preprocessorFile, ModelNames.CampPlus.modelFile]
        )
    }

    private var managedRecordingDestinations: [URL] {
        [
            (configuration.destination, configuration.managesDestination),
            (configuration.sortformerDestination, configuration.managesSortformerDestination),
            (configuration.campPlusDestination, configuration.managesCampPlusDestination)
        ].compactMap { destination, isManaged in isManaged ? destination : nil }
    }

    private func stagingURL(for destination: URL) -> URL {
        URL(filePath: destination.path + ".download", directoryHint: .isDirectory)
    }

    private func installedRecordingModels() -> RecordingModelInstallation? {
        let asr = bundle
        guard asr.isInstalled,
              DiarizationModelStore.isSortformerInstalled(at: configuration.sortformerDestination),
              DiarizationModelStore.isCampPlusInstalled(at: configuration.campPlusDestination)
        else { return nil }
        return RecordingModelInstallation(
            asr: asr,
            sortformerModel: configuration.sortformerDestination,
            campPlusDirectory: configuration.campPlusDestination
        )
    }

    private static func recordingState(for configuration: Configuration) -> ASRModelDownloadState {
        let asr = ASRModelBundle(variant: configuration.variant, directory: configuration.destination)
        guard asr.isInstalled,
              DiarizationModelStore.isSortformerInstalled(at: configuration.sortformerDestination),
              DiarizationModelStore.isCampPlusInstalled(at: configuration.campPlusDestination)
        else { return .notInstalled }
        let installation = RecordingModelInstallation(
            asr: asr,
            sortformerModel: configuration.sortformerDestination,
            campPlusDirectory: configuration.campPlusDestination
        )
        return .installed(byteCount: installation.byteCount)
    }
}

