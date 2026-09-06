import Foundation
import Observation
import TranscriptCore

/// Drives the on-demand fetch of the ~665 MB CoreML bundle.
@MainActor
@Observable
final class ModelDownloadModel {
    private(set) var state: ASRModelDownloadState = .notInstalled
    private(set) var isWorking = false

    private let services: AppServices
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    var statusText: String {
        let localization = LocalizationManager.shared
        switch state {
        case .notInstalled: return localization.localized("Not downloaded")
        case .downloading(let done, let total):
            guard total > 0 else { return localization.localized("Starting…") }
            return localization.localized("\(Format.bytes(Int(done))) of \(Format.bytes(Int(total)))")
        case .verifying: return localization.localized("Verifying")
        case .installed(let bytes): return Format.bytes(Int(bytes))
        case .failed(let message): return message
        }
    }

    var isInstalled: Bool { if case .installed = state { true } else { false } }

    func observe() {
        guard observation == nil else { return }
        let downloader = services.modelDownloader
        observation = Task { [weak self] in
            for await state in await downloader.states() {
                self?.state = state
            }
        }
    }

    func download() async {
        isWorking = true
        defer { isWorking = false }
        _ = try? await services.modelDownloader.ensureRecordingModelsInstalled()
    }

    func cancel() async {
        await services.modelDownloader.cancel()
    }

    func remove() async {
        try? await services.modelDownloader.remove()
    }
}
