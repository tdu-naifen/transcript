import CoreML
import FluidAudio
import Foundation
import Testing
@testable import TranscriptCore

@Test func asrBundleRejectsEmptyCompiledModels() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ASRModelBundle.requiredNames {
        let url = root.appending(path: name, directoryHint: name.hasSuffix(".mlmodelc") ? .isDirectory : .notDirectory)
        if name.hasSuffix(".mlmodelc") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("{}".utf8).write(to: url)
        }
    }

    let bundle = ASRModelBundle(variant: .multilingual2240ms, directory: root)
    #expect(!bundle.isInstalled)
}

@Test func diarizationStoresRejectEmptyCompiledModels() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let sortformer = root.appending(path: "Sortformer_v2.1.mlmodelc", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sortformer, withIntermediateDirectories: true)
    #expect(!DiarizationModelStore.isSortformerInstalled(at: sortformer))

    for name in [ModelNames.CampPlus.preprocessorFile, ModelNames.CampPlus.modelFile] {
        try FileManager.default.createDirectory(
            at: root.appending(path: name, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }
    #expect(!DiarizationModelStore.isCampPlusInstalled(at: root))
}

@Test func modelManifestPathsAllowNestingButRejectTraversal() {
    let source = ModelAssetSource(
        repository: "owner/model", revision: "revision", prefix: "models/v1", includedRoots: [])
    #expect(source.safeRelativePath(for: "models/v1/model0/weights.bin") == "model0/weights.bin")
    #expect(source.safeRelativePath(for: "models/v1/../escape.bin") == nil)
    #expect(source.safeRelativePath(for: "../escape.bin") == nil)
    #expect(source.safeRelativePath(for: "/absolute.bin") == nil)
    #expect(source.safeRelativePath(for: "models/v1//empty.bin") == nil)
}

private actor StubModelFetcher: ModelAssetFetching {
    enum Action: Sendable { case fail, waitForCancellation, succeed }
    enum StubFailure: Error { case network }

    private var actions: [Action]
    private(set) var destinations: [URL] = []

    init(actions: [Action]) {
        self.actions = actions
    }

    func byteCount(source: ModelAssetSource) -> Int64 {
        100
    }

    func fetch(
        source: ModelAssetSource,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws {
        destinations.append(destination)
        let action = actions.removeFirst()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: destination.appending(path: "transfer.partial"))
        await progress(7, 100)
        switch action {
        case .fail:
            throw StubFailure.network
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(30))
        case .succeed:
            break
        }
        try? FileManager.default.removeItem(at: destination)
        try makeValidFixture(for: source, at: destination)
        await progress(100, 100)
    }

    private func makeValidFixture(for source: ModelAssetSource, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if source.includedRoots == ASRModelBundle.requiredNames {
            for name in ASRModelBundle.requiredNames {
                try makeFixtureAsset(at: root.appending(path: name))
            }
        } else if source.includedRoots.isEmpty {
            try Data("coreml".utf8).write(to: root.appending(path: "coremldata.bin"))
        } else {
            for name in source.includedRoots {
                try makeFixtureAsset(at: root.appending(path: name))
            }
        }
    }

    private func makeFixtureAsset(at url: URL) throws {
        let name = url.lastPathComponent
        if name.hasSuffix(".mlmodelc") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("coreml".utf8).write(to: url.appending(path: "coremldata.bin"))
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
    }
}

private func temporaryDownloader(fetcher: any ModelAssetFetching) -> (ASRModelDownloader, URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let configuration = ASRModelDownloader.Configuration(
        destination: root.appending(path: "asr", directoryHint: .isDirectory),
        sortformerDestination: root.appending(path: "sortformer.mlmodelc", directoryHint: .isDirectory),
        campPlusDestination: root.appending(path: "campplus", directoryHint: .isDirectory)
    )
    return (ASRModelDownloader(configuration: configuration, fetcher: fetcher), root)
}

@Test func modelInstallFailureIsAtomicAndRetrySucceeds() async throws {
    let fetcher = StubModelFetcher(actions: [.fail, .succeed])
    let (downloader, root) = temporaryDownloader(fetcher: fetcher)
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appending(path: "asr", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: existing.appending(path: "existing-marker"))

    do {
        _ = try await downloader.ensureInstalled()
        Issue.record("Expected first download to fail")
    } catch is StubModelFetcher.StubFailure {}
    #expect(FileManager.default.fileExists(atPath: existing.appending(path: "existing-marker").path))

    let installed = try await downloader.ensureInstalled()
    #expect(installed.isInstalled)
    #expect(!FileManager.default.fileExists(atPath: existing.appending(path: "existing-marker").path))
    let destinations = await fetcher.destinations
    #expect(destinations.count == 2)
    #expect(destinations.first == destinations.last)
}

@Test func modelInstallCancellationDoesNotPublishPartialDestination() async throws {
    let fetcher = StubModelFetcher(actions: [.waitForCancellation])
    let (downloader, root) = temporaryDownloader(fetcher: fetcher)
    defer { try? FileManager.default.removeItem(at: root) }

    let task = Task { try await downloader.ensureInstalled() }
    while await fetcher.destinations.isEmpty { await Task.yield() }
    await downloader.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {}

    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "asr").path))
    #expect(await downloader.state == .notInstalled)
}

@Test func modelInstallPublishesByteProgress() async throws {
    let fetcher = StubModelFetcher(actions: [.succeed])
    let (downloader, root) = temporaryDownloader(fetcher: fetcher)
    defer { try? FileManager.default.removeItem(at: root) }

    let stream = await downloader.states()
    let states = Task { () -> [ASRModelDownloadState] in
        var values: [ASRModelDownloadState] = []
        for await value in stream {
            values.append(value)
            if case .installed = value { break }
        }
        return values
    }
    _ = try await downloader.ensureInstalled()
    let values = await states.value
    #expect(values.contains(.downloading(completedBytes: 7, totalBytes: 100)))
    #expect(values.contains(.verifying))
}

@Test func recordingModelInstallPublishesAggregateProgressAndCoalescesRequests() async throws {
    let fetcher = StubModelFetcher(actions: [.succeed, .succeed, .succeed])
    let (downloader, root) = temporaryDownloader(fetcher: fetcher)
    defer { try? FileManager.default.removeItem(at: root) }

    let stream = await downloader.states()
    let states = Task { () -> [ASRModelDownloadState] in
        var values: [ASRModelDownloadState] = []
        for await value in stream {
            values.append(value)
            if case .installed = value { break }
        }
        return values
    }
    async let first = downloader.ensureRecordingModelsInstalled()
    async let second = downloader.ensureRecordingModelsInstalled()
    let (firstInstallation, secondInstallation) = try await (first, second)

    #expect(firstInstallation == secondInstallation)
    #expect(firstInstallation.asr.isInstalled)
    #expect(DiarizationModelStore.isSortformerInstalled(at: firstInstallation.sortformerModel))
    #expect(DiarizationModelStore.isCampPlusInstalled(at: firstInstallation.campPlusDirectory))
    #expect(await fetcher.destinations.count == 3)
    let progress = await states.value.compactMap { state -> (Int64, Int64)? in
        guard case .downloading(let completed, let total) = state else { return nil }
        return (completed, total)
    }
    #expect(!progress.isEmpty)
    #expect(progress.allSatisfy { $0.1 == 300 })
    #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
}

@Test func recordingModelCancellationDuringSortformerCanRetry() async throws {
    let fetcher = StubModelFetcher(actions: [.succeed, .waitForCancellation, .succeed, .succeed])
    let (downloader, root) = temporaryDownloader(fetcher: fetcher)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = Task { try await downloader.ensureRecordingModelsInstalled() }
    while await fetcher.destinations.count < 2 { await Task.yield() }
    await downloader.cancel()
    do {
        _ = try await first.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {}

    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "sortformer.mlmodelc").path))
    #expect(await downloader.state == .notInstalled)
    let installed = try await downloader.ensureRecordingModelsInstalled()
    #expect(DiarizationModelStore.isSortformerInstalled(at: installed.sortformerModel))
    #expect(DiarizationModelStore.isCampPlusInstalled(at: installed.campPlusDirectory))
}

@Test func removingRecordingModelsClearsAllPublishedAndStagedAssets() async throws {
    let fetcher = StubModelFetcher(actions: [.succeed, .succeed, .succeed])
    let (downloader, root) = temporaryDownloader(fetcher: fetcher)
    defer { try? FileManager.default.removeItem(at: root) }

    let installation = try await downloader.ensureRecordingModelsInstalled()
    try await downloader.remove()

    #expect(!FileManager.default.fileExists(atPath: installation.asr.directory.path))
    #expect(!FileManager.default.fileExists(atPath: installation.sortformerModel.path))
    #expect(!FileManager.default.fileExists(atPath: installation.campPlusDirectory.path))
    #expect(await downloader.state == .notInstalled)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPT_RUN_MODEL_DOWNLOAD"] == "1"))
func genuineRecordingModelDownloadAndLoad() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "transcript-real-model-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!FileManager.default.fileExists(atPath: root.path))

    let configuration = ASRModelDownloader.Configuration(
        destination: root.appending(path: "nemotron/multilingual/2240ms", directoryHint: .isDirectory),
        sortformerDestination: root.appending(
            path: "sortformer/v3/palettized/Sortformer_v2.1.mlmodelc", directoryHint: .isDirectory),
        campPlusDestination: root.appending(path: "campplus", directoryHint: .isDirectory)
    )
    let downloader = ASRModelDownloader(configuration: configuration)
    let installation = try await downloader.ensureRecordingModelsInstalled()
    print("REAL_MODEL_ROOT=\(root.path)")
    print("REAL_MODEL_BYTES=\(installation.byteCount)")

    _ = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: installation.asr.directory)
    _ = try MLModel(contentsOf: installation.sortformerModel)
    _ = try CampPlusModels.load(from: installation.campPlusDirectory)
    print("REAL_MODEL_COREML_LOAD=success")
}