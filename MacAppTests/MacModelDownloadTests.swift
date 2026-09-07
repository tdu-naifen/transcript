import CryptoKit
import Foundation
import TranscriptCore
import XCTest
@testable import TranscriptMac

private actor FixtureModelDownloader: MacModelDownloading {
    let locations: [MacModelCategory: URL]
    var failures: Set<MacModelCategory>
    let waitsForCancellation: Bool
    private(set) var calls: [MacModelCategory] = []
    private(set) var cancellations = 0

    init(locations: [MacModelCategory: URL], failures: Set<MacModelCategory> = [],
         waitsForCancellation: Bool = false) {
        self.locations = locations
        self.failures = failures
        self.waitsForCancellation = waitsForCancellation
    }

    func install(category: MacModelCategory,
                 progress: @escaping @Sendable (ASRModelDownloadState) async -> Void) async throws -> URL {
        calls.append(category)
        await progress(.downloading(completedBytes: 50, totalBytes: 100))
        if waitsForCancellation { try await Task.sleep(for: .seconds(60)) }
        if failures.remove(category) != nil {
            throw MacProcessingError.transcriptionFailed("Fixture download failure")
        }
        await progress(.verifying)
        return try XCTUnwrap(locations[category])
    }

    func cancel() { cancellations += 1 }
}

private actor FixturePinnedModelTransport {
    let source: URL
    var integrityFailures: Int
    let networkFailure: Bool
    private(set) var fetched: [URL] = []
    private(set) var verified: [URL] = []

    init(source: URL, integrityFailures: Int = 0, networkFailure: Bool = false) {
        self.source = source
        self.integrityFailures = integrityFailures
        self.networkFailure = networkFailure
    }

    func fetch(_ category: MacModelCategory, to destination: URL,
               progress: @escaping MacCoreModelDownloader.Progress) async throws {
        fetched.append(destination)
        try FileManager.default.copyItem(at: source, to: destination)
        await progress(.downloading(completedBytes: 100, totalBytes: 100))
    }

    func verify(_ category: MacModelCategory, at url: URL) throws {
        verified.append(url)
        if networkFailure { throw URLError(.networkConnectionLost) }
        if integrityFailures > 0 {
            integrityFailures -= 1
            throw MacModelArtifactVerifier.Failure.invalidFile("encoder.mlmodelc/weights/weight.bin")
        }
    }
}

@MainActor
final class MacModelDownloadTests: XCTestCase {
    private func locations(in root: URL) throws -> [MacModelCategory: URL] {
        let asr = try MacProcessingTestFixtures.asr(in: root)
        let sortformer = root.appendingPathComponent("sortformer.mlmodelc")
        let campPlus = root.appendingPathComponent("campplus")
        for compiled in [sortformer, campPlus.appendingPathComponent("CamPlusPreprocessor.mlmodelc"),
                         campPlus.appendingPathComponent("CamPlusPlus.mlmodelc")] {
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data("fixture only".utf8).write(to: compiled.appendingPathComponent("coremldata.bin"))
        }
        return [.asr: asr.directory, .diarization: sortformer, .speakerEmbedding: campPlus]
    }

    func testInstallAllPersistsValidatedFilesWithoutChangingSelectionsOrLanguage() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try locations(in: root)
        let downloader = FixtureModelDownloader(locations: urls)
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, meeting) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        let before = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        var imported = MacModelCard.builtins[0]
        imported.id = "imported-card"
        try model.catalog.add(imported)
        try model.catalog.select(imported.id, category: .asr)
        try model.catalog.setLanguage("zh-CN")
        model.installCompatibleModels()
        XCTAssertTrue(model.isDownloading)
        await model.waitForDownloads()
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.downloads.map(\.stage), [.installed, .installed, .installed])
        XCTAssertEqual(model.downloadProgress, 1)
        let calls = await downloader.calls
        XCTAssertEqual(calls, MacModelCategory.allCases)
        let restored = MacModelCatalog()
        try restored.load(directory: root)
        XCTAssertEqual(restored.selected(.asr)?.id, imported.id)
        XCTAssertEqual(restored.language, "zh-CN")
        for category in MacModelCategory.allCases {
            let card = try XCTUnwrap(restored.cards.first { $0.category == category && $0.adapter != .cardOnly })
            XCTAssertEqual(try card.resolvedURL().path, urls[category]?.path)
            XCTAssertTrue(card.isInstalled())
        }
        XCTAssertFalse(model.canRun, "Installing weights must not select an unsupported imported card.")
        let after = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(before, after)
    }

    func testFailureKeepsSuccessfulModelsAndRetryOnlyDownloadsUnfinishedModel() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureModelDownloader(locations: try locations(in: root), failures: [.diarization])
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        model.installCompatibleModels()
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.map(\.stage), [.installed, .failed, .installed])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.catalog.selected(.diarization)?.localPath)
        model.retryDownloads()
        await model.waitForDownloads()
        let calls = await downloader.calls
        XCTAssertEqual(calls, [.asr, .diarization, .speakerEmbedding, .diarization])
        XCTAssertEqual(model.downloads.map(\.stage), [.installed])
        XCTAssertNil(model.errorMessage)
    }

    func testInvalidDownloaderResultCannotBeReportedAsInstalled() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureModelDownloader(locations: [.asr: root.appendingPathComponent("missing")])
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        model.installCompatibleModels(categories: [.asr])
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.first?.stage, .failed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.catalog.selected(.asr)?.localPath)
    }

    func testCancellationDrainsAndReconfigurationCannotResetActiveProgress() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureModelDownloader(locations: try locations(in: root), waitsForCancellation: true)
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        model.installCompatibleModels()
        for _ in 0..<1_000 {
            if model.downloads.first?.completedBytes == 50 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.downloads.first?.completedBytes, 50)
        model.configure(context: context)
        XCTAssertEqual(model.downloads.first?.completedBytes, 50)
        model.installCompatibleModels()
        XCTAssertNotNil(model.errorMessage, "Duplicate attempts must explain why they cannot start.")
        model.cancelDownload()
        XCTAssertTrue(model.isCancellingDownload)
        await model.waitForDownloads()
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.downloads.map(\.stage), [.cancelled, .cancelled, .cancelled])
        XCTAssertNil(model.catalog.selected(.asr)?.localPath)
        let calls = await downloader.calls
        XCTAssertEqual(calls, [.asr])
    }

    func testUnconfiguredInstallationReportsActionableError() async {
        let downloader = FixtureModelDownloader(locations: [:])
        let model = MacProcessingModel(makeDownloader: { downloader })
        model.installCompatibleModels()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isDownloading)
        let calls = await downloader.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCatalogWriteFailureCannotReportDownloadSuccess() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FixtureModelDownloader(locations: try locations(in: root))
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mac-model-catalog.json"),
                                                withIntermediateDirectories: true)
        model.installCompatibleModels(categories: [.asr])
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.first?.stage, .failed)
        XCTAssertNil(model.catalog.selected(.asr)?.localPath)
        XCTAssertNotNil(model.errorMessage)
    }

    func testPinnedVerifierRejectsSameSizeCorruptionAndUnsafeManifest() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("weight.bin")
        let data = Data("verified fixture".utf8)
        try data.write(to: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = MacModelArtifactVerifier.Entry(type: "file", path: "prefix/weight.bin",
            size: Int64(data.count), oid: nil, lfs: .init(oid: hash, size: Int64(data.count)))
        XCTAssertNoThrow(try MacModelArtifactVerifier.verify(entries: [entry], prefix: "prefix",
                                                            roots: [], at: root))
        try Data(repeating: 0, count: data.count).write(to: file)
        XCTAssertThrowsError(try MacModelArtifactVerifier.verify(entries: [entry], prefix: "prefix",
                                                                roots: [], at: root))
        let traversal = MacModelArtifactVerifier.Entry(type: "file", path: "prefix/../weight.bin",
            size: Int64(data.count), oid: nil, lfs: .init(oid: hash, size: Int64(data.count)))
        XCTAssertThrowsError(try MacModelArtifactVerifier.verify(entries: [traversal], prefix: "prefix",
                                                                roots: [], at: root))
        XCTAssertThrowsError(try MacModelArtifactVerifier.verify(entries: [], prefix: "", roots: [], at: root))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try MacModelArtifactVerifier.verify(entries: [entry], prefix: "prefix",
                                                                roots: [], at: root)) { error in
            guard case MacModelArtifactVerifier.Failure.invalidFile(let path) = error else {
                return XCTFail("Missing pinned weights must trigger persistent rejection, not a transient error: \(error)")
            }
            XCTAssertEqual(path, "weight.bin")
        }
    }

    func testPinnedVerifierChecksGitBlobHashForNonLFSFiles() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("{}".utf8)
        try data.write(to: root.appendingPathComponent("metadata.json"))
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        let hash = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        let entry = MacModelArtifactVerifier.Entry(type: "file", path: "metadata.json",
                                                   size: Int64(data.count), oid: hash, lfs: nil)
        XCTAssertNoThrow(try MacModelArtifactVerifier.verify(entries: [entry], prefix: "",
                                                            roots: ["metadata.json"], at: root))
        try Data("[]".utf8).write(to: root.appendingPathComponent("metadata.json"))
        XCTAssertThrowsError(try MacModelArtifactVerifier.verify(entries: [entry], prefix: "",
                                                                roots: ["metadata.json"], at: root))
    }

    private func selectASRPath(_ path: URL, library: URL) throws {
        let catalog = MacModelCatalog()
        try catalog.load(directory: library)
        try catalog.save()
        let file = library.appendingPathComponent("mac-model-catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var cards = try XCTUnwrap(json["cards"] as? [[String: Any]])
        let index = try XCTUnwrap(cards.firstIndex { $0["id"] as? String == "nemotron-coreml" })
        cards[index]["localPath"] = path.path
        json["cards"] = cards
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
    }

    private func stagedDownloader(root: URL, existing: URL?,
                                  transport: FixturePinnedModelTransport) -> MacCoreModelDownloader {
        MacCoreModelDownloader(root: root, existingURLs: existing.map { [.asr: $0] } ?? [:],
            fetch: { try await transport.fetch($0, to: $1, progress: $2) },
            verify: { try await transport.verify($0, at: $1) })
    }

    func testFreshIntegrityFailureNeverPublishesAndRetryRepairs() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try MacProcessingTestFixtures.asr(in: root)
        let managed = root.appendingPathComponent("isolated-managed")
        let published = MacManagedModelStore.publishedURL(.asr, root: managed)
        let legacy = root.appendingPathComponent("unused-default")
        try selectASRPath(published, library: root)
        let transport = FixturePinnedModelTransport(source: source.directory, integrityFailures: 1)
        let downloader = stagedDownloader(root: managed, existing: legacy, transport: transport)
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        model.installCompatibleModels(categories: [.asr])
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.first?.stage, .failed)
        XCTAssertFalse(model.canRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(model.catalog.selected(.asr)?.isInstalled() ?? true)
        let staged = try FileManager.default.contentsOfDirectory(atPath: managed.appendingPathComponent("staging").path)
        XCTAssertTrue(staged.isEmpty)
        model.retryDownloads()
        await model.waitForDownloads()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.downloads.first?.stage, .installed)
        XCTAssertTrue(model.canRun)
        XCTAssertTrue(MacModelCard.isInstalled(adapter: .nemotronMultilingual, at: published))
        let fetched = await transport.fetched
        XCTAssertEqual(fetched.count, 2)
        XCTAssertNotEqual(fetched[0], fetched[1], "Retry must not reuse rejected staged weights.")
        XCTAssertTrue(fetched.allSatisfy { $0.path.hasPrefix(managed.appendingPathComponent("staging").path) })
    }

    func testManagedLayoutWithoutValidationReceiptCannotRun() throws {
        let root = MacManagedModelStore.root.appendingPathComponent("verification-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try MacProcessingTestFixtures.asr(in: root)
        XCTAssertTrue(bundle.isInstalled, "Core intentionally checks only the compiled layout.")
        XCTAssertFalse(MacModelCard.isInstalled(adapter: .nemotronMultilingual, at: bundle.directory))
        try MacManagedModelStore.record(category: .asr, at: bundle.directory, rejected: false)
        XCTAssertTrue(MacModelCard.isInstalled(adapter: .nemotronMultilingual, at: bundle.directory))
        try MacManagedModelStore.record(category: .asr, at: bundle.directory, rejected: true)
        XCTAssertFalse(MacModelCard.isInstalled(adapter: .nemotronMultilingual, at: bundle.directory))
    }

    func testRejectedLegacyModelIsPersistentlyBlockedAndRetrySelectsVerifiedRepair() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try MacProcessingTestFixtures.asr(in: root)
        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.copyItem(at: source.directory, to: legacy)
        try selectASRPath(legacy, library: root)
        let managed = root.appendingPathComponent("isolated-managed")
        let transport = FixturePinnedModelTransport(source: source.directory, integrityFailures: 1)
        let downloader = stagedDownloader(root: managed, existing: legacy, transport: transport)
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        model.installCompatibleModels(categories: [.asr])
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.first?.stage, .failed)
        XCTAssertFalse(model.canRun)
        XCTAssertTrue(MacManagedModelStore.isRejected(legacy))
        XCTAssertEqual(model.catalog.selected(.asr)?.installationDescription, "Integrity check failed · unavailable")
        XCTAssertTrue(MacModelCard.hasCompatibleLayout(adapter: .nemotronMultilingual, at: legacy))
        XCTAssertFalse(MacModelCard.isInstalled(adapter: .nemotronMultilingual, at: legacy))
        let reloaded = MacProcessingModel()
        reloaded.configure(context: context)
        XCTAssertFalse(reloaded.canRun, "A relaunch must not trust a rejected layout-installed folder.")
        model.retryDownloads()
        await model.waitForDownloads()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(try model.catalog.selected(.asr)?.resolvedURL().path,
                       MacManagedModelStore.publishedURL(.asr, root: managed).path)
        XCTAssertTrue(MacManagedModelStore.isRejected(legacy), "Do not rehabilitate rejected legacy bytes.")
        let fetched = await transport.fetched
        XCTAssertEqual(fetched.count, 1)
        let restored = MacModelCatalog()
        try restored.load(directory: root)
        XCTAssertEqual(restored.selected(.asr)?.localPath, model.catalog.selected(.asr)?.localPath)
    }

    func testPreviouslyVerifiedModelSurvivesTransientVerificationFailure() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try MacProcessingTestFixtures.asr(in: root)
        try MacManagedModelStore.record(category: .asr, at: source.directory, rejected: false)
        try selectASRPath(source.directory, library: root)
        let transport = FixturePinnedModelTransport(source: source.directory, networkFailure: true)
        let downloader = stagedDownloader(root: root.appendingPathComponent("managed"),
                                           existing: source.directory, transport: transport)
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        XCTAssertTrue(model.canRun)
        model.installCompatibleModels(categories: [.asr])
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.first?.stage, .failed)
        XCTAssertTrue(model.canRun)
        XCTAssertFalse(MacManagedModelStore.isRejected(source.directory))
        XCTAssertEqual(try model.catalog.selected(.asr)?.resolvedURL().path, source.directory.path)
        let fetched = await transport.fetched
        XCTAssertTrue(fetched.isEmpty)
    }

    func testUserLocatedModelIsNotModifiedOrReplacedByFailedOrSuccessfulManagedInstall() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try MacProcessingTestFixtures.asr(in: root)
        let transport = FixturePinnedModelTransport(source: source.directory, integrityFailures: 1)
        let downloader = stagedDownloader(root: root.appendingPathComponent("managed"), existing: nil,
                                           transport: transport)
        let model = MacProcessingModel(makeDownloader: { downloader })
        let (context, _) = try await MacProcessingTestFixtures.context(in: root)
        model.configure(context: context)
        try model.catalog.locate(source.directory, cardID: "nemotron-coreml")
        let card = try XCTUnwrap(model.catalog.selected(.asr))
        let original = try Data(contentsOf: source.directory.appendingPathComponent("encoder.mlmodelc/coremldata.bin"))
        model.installCompatibleModels(categories: [.asr])
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.first?.stage, .failed)
        XCTAssertTrue(model.canRun)
        model.retryDownloads()
        await model.waitForDownloads()
        XCTAssertEqual(model.downloads.first?.stage, .installed)
        XCTAssertEqual(model.catalog.selected(.asr), card)
        XCTAssertEqual(try Data(contentsOf: source.directory.appendingPathComponent("encoder.mlmodelc/coremldata.bin")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MacManagedModelStore.validationURL(source.directory).path))
    }

    func testOptInInstallProductionBuiltins() async throws {
        guard ProcessInfo.processInfo.environment["RUN_MAC_INSTALL_BUILTINS"] == "1" else {
            throw XCTSkip("Set RUN_MAC_INSTALL_BUILTINS=1 in the sandbox-hosted Mac test app to install public pinned weights.")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        XCTAssertTrue(support.path.contains("/Containers/com.transcript.TranscriptMac/Data/"))
        let catalog = MacModelCatalog()
        let directory = support.appendingPathComponent("TranscriptMac")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try catalog.load(directory: directory)
        let selections = catalog.selections
        let language = catalog.language
        for builtin in MacModelCard.builtins {
            let downloader = MacCoreModelDownloader()
            let url = try await downloader.install(category: builtin.category) { _ in }
            XCTAssertTrue(MacModelCard.isInstalled(adapter: builtin.adapter, at: url))
            XCTAssertTrue(MacManagedModelStore.isManaged(url))
            try catalog.useManagedModel(category: builtin.category, at: url)
            XCTAssertEqual(catalog.cards.first { $0.id == builtin.id }?.revision, builtin.revision)
        }
        let restored = MacModelCatalog()
        try restored.load(directory: directory)
        XCTAssertEqual(restored.selections, selections)
        XCTAssertEqual(restored.language, language)
        XCTAssertTrue(MacModelCard.builtins.allSatisfy { builtin in
            restored.cards.first { $0.id == builtin.id }?.isInstalled() == true
        })
    }
}
