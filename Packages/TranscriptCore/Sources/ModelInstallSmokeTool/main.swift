import CoreML
import FluidAudio
import Foundation
import TranscriptCore

@main
struct ModelInstallSmokeTool {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let isResume = arguments.first == "--resume"
        let paths = isResume ? Array(arguments.dropFirst()) : arguments
        guard paths.count == 1 else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "usage: model-install-smoke [--resume] <directory>"
            ])
        }
        let root = URL(filePath: paths[0], directoryHint: .isDirectory)
        guard isResume || !FileManager.default.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: root.path])
        }

        let configuration = ASRModelDownloader.Configuration(
            destination: root.appending(path: "nemotron/multilingual/2240ms", directoryHint: .isDirectory),
            sortformerDestination: root.appending(
                path: "sortformer/v3/palettized/Sortformer_v2.1.mlmodelc", directoryHint: .isDirectory),
            campPlusDestination: root.appending(path: "campplus", directoryHint: .isDirectory)
        )
        let downloader = ASRModelDownloader(configuration: configuration)
        print("MODEL_SOURCE_NEMOTRON=https://huggingface.co/\(Repo.nemotronMultilingual.remotePath)/tree/\(ASRModelDownloader.nemotronRevision)")
        print("MODEL_SOURCE_SORTFORMER=https://huggingface.co/\(Repo.sortformer.remotePath)/tree/\(ASRModelDownloader.sortformerRevision)")
        print("MODEL_SOURCE_CAMPPLUS=https://huggingface.co/\(Repo.campPlus.remotePath)/tree/\(ASRModelDownloader.campPlusRevision)")
        let states = await downloader.states()
        let reporter = Task {
            for await state in states {
                if case .downloading(let completed, let total) = state {
                    print("MODEL_PROGRESS=\(completed)/\(total)")
                }
            }
        }
        defer { reporter.cancel() }

        let started = ContinuousClock.now
        let installation = try await downloader.ensureRecordingModelsInstalled()
        let elapsed = started.duration(to: .now)
        print("REAL_MODEL_ROOT=\(root.path)")
        print("REAL_MODEL_NEMOTRON_BYTES=\(installation.asr.byteCount)")
        print("REAL_MODEL_SORTFORMER_BYTES=\(byteCount(at: installation.sortformerModel))")
        print("REAL_MODEL_CAMPPLUS_BYTES=\(byteCount(at: installation.campPlusDirectory))")
        print("REAL_MODEL_BYTES=\(installation.byteCount)")
        print("REAL_MODEL_DOWNLOAD_SECONDS=\(elapsed.components.seconds)")
        _ = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: installation.asr.directory)
        _ = try MLModel(contentsOf: installation.sortformerModel)
        _ = try CampPlusModels.load(from: installation.campPlusDirectory)
        print("REAL_MODEL_COREML_LOAD=success")
    }

    private static func byteCount(at root: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
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