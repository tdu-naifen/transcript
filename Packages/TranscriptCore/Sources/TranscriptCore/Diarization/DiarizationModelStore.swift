import FluidAudio
import Foundation

/// Resolves existing local diarization and voiceprint models before the downloader
/// chooses managed Application Support destinations.
public enum DiarizationModelStore {
    /// Set to a checkout's `Models/sortformer-diarization` to run without moving files
    /// into Application Support first.
    public static let sortformerOverrideEnvironmentKey = "TRANSCRIPT_DIARIZATION_MODEL_ROOT"
    /// Set to a checkout's `Models/campplus-embedder`.
    public static let campPlusOverrideEnvironmentKey = "TRANSCRIPT_VOICEPRINT_MODEL_ROOT"

    public static var sortformerApplicationSupportRoot: URL {
        applicationSupportBase().appending(path: "Models/sortformer-diarization", directoryHint: .isDirectory)
    }

    public static var campPlusApplicationSupportRoot: URL {
        applicationSupportBase().appending(path: "Models/campplus-embedder", directoryHint: .isDirectory)
    }

    public static func sortformerSearchRoots(bundle: Bundle = .main) -> [URL] {
        searchRoots(
            overrideKey: sortformerOverrideEnvironmentKey,
            resourceName: "sortformer-diarization",
            applicationSupportRoot: sortformerApplicationSupportRoot,
            bundle: bundle
        )
    }

    public static func campPlusSearchRoots(bundle: Bundle = .main) -> [URL] {
        searchRoots(
            overrideKey: campPlusOverrideEnvironmentKey,
            resourceName: "campplus-embedder",
            applicationSupportRoot: campPlusApplicationSupportRoot,
            bundle: bundle
        )
    }

    /// Compiled-model path FluidAudio's `ModelNames.Sortformer` naming already defines
    /// (`v3/<precision>/<Variant>.mlmodelc`) — reused here instead of hardcoding it, so
    /// the store never drifts from what `SortformerDiarizer.initialize(mainModelPath:)`
    /// actually expects.
    ///
    /// Defaults to ``SortformerConfig/transcriptDefault``'s variant/precision: `fastV2_1`,
    /// palettized only. Never pass `.fp16` here for a high-context variant — see that
    /// default's doc comment.
    public static func sortformerMainModelPath(
        variant: SortformerConfig.ModelVariant = .fastV2_1,
        precision: ModelNames.Sortformer.ModelPrecision = .palettized,
        searchRoots: [URL] = DiarizationModelStore.sortformerSearchRoots()
    ) -> URL {
        let relative = variant.fileName(precision: precision)
        for root in searchRoots {
            let candidate = root.appending(path: relative, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return sortformerApplicationSupportRoot.appending(path: relative, directoryHint: .isDirectory)
    }

    /// Directory containing `CamPlusPreprocessor.mlmodelc` + `CamPlusPlus.mlmodelc`,
    /// as ``CampPlusModels/load(from:)`` expects.
    public static func campPlusDirectory(
        searchRoots: [URL] = DiarizationModelStore.campPlusSearchRoots()
    ) -> URL {
        for root in searchRoots where isCampPlusInstalled(at: root) { return root }
        return campPlusApplicationSupportRoot
    }

    public static func isSortformerInstalled(at path: URL) -> Bool {
        ModelAssetValidation.isValidCompiledModel(at: path)
    }

    public static func isCampPlusInstalled(at directory: URL) -> Bool {
        return [ModelNames.CampPlus.preprocessorFile, ModelNames.CampPlus.modelFile].allSatisfy {
            ModelAssetValidation.isValidCompiledModel(at: directory.appending(path: $0))
        }
    }

    private static func searchRoots(
        overrideKey: String,
        resourceName: String,
        applicationSupportRoot: URL,
        bundle: Bundle
    ) -> [URL] {
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            roots.append(URL(filePath: override, directoryHint: .isDirectory))
        }
        if let resource = bundle.resourceURL {
            roots.append(resource.appending(path: resourceName, directoryHint: .isDirectory))
        }
        roots.append(applicationSupportRoot)
        return roots
    }

    private static func applicationSupportBase() -> URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
    }
}
