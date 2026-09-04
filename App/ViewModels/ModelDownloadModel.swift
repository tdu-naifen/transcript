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
        switch state {
        case .notInstalled: "Not downloaded"
        case .downloading(let done, let total):
            total > 0
                ? "\(Format.bytes(Int(done))) of \(Format.bytes(Int(total)))"
                : "Starting…"
        case .verifying: "Verifying"
        case .installed(let bytes): Format.bytes(Int(bytes))
        case .failed(let message): message
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
        _ = try? await services.modelDownloader.ensureInstalled()
    }

    func cancel() async {
        await services.modelDownloader.cancel()
    }

    func remove() async {
        try? await services.modelDownloader.remove()
    }
}
