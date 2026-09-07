import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MacBackupController {
    private(set) var folderPath: String?
    private(set) var isBusy = false
    private(set) var status: String?
    private(set) var errorMessage: String?
    private(set) var lastSnapshot: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var cancellation: MacBackupCancellation?
    @ObservationIgnored private static let bookmarkKey = "MacBackup.folderBookmark.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.data(forKey: Self.bookmarkKey) != nil {
            do {
                let folder = try resolveFolder()
                folderPath = folder.path
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var hasFolder: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    func chooseFolder(contextProvider: @MainActor () async throws -> MacLibraryContext) async {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Backup Folder", table: "Backup")
        panel.prompt = String(localized: "Choose Folder", table: "Backup")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let folderPath { panel.directoryURL = URL(fileURLWithPath: folderPath) }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        await selectFolder(folder, contextProvider: contextProvider)
    }

    func selectFolder(_ folder: URL, contextProvider: @MainActor () async throws -> MacLibraryContext) async {
        guard !isBusy else { return }
        let token = begin()
        defer { finish() }
        do {
            let context = try await contextProvider()
            try token.check()
            let bookmark = try await Task.detached(priority: .userInitiated) {
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                try token.check()
                try MacBackupService.validateDestination(folder, context: context)
                return try folder.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
                )
            }.value
            try token.check()
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            folderPath = folder.path
            lastSnapshot = nil
            status = String(localized: "Backup folder selected. Your working library stays on this Mac.", table: "Backup")
        } catch is CancellationError {
            status = String(localized: "Folder selection cancelled.", table: "Backup")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func backup(contextProvider: @MainActor () async throws -> MacLibraryContext) async {
        guard !isBusy else { return }
        let token = begin()
        defer { finish() }
        do {
            let folder = try resolveFolder()
            folderPath = folder.path
            let context = try await contextProvider()
            try token.check()
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                return try MacBackupService.create(context: context, destination: folder, cancellation: token)
            }.value
            lastSnapshot = snapshot
            status = String(localized: "Backup complete locally. Cloud upload status is managed by macOS, not verified by this app.", table: "Backup")
        } catch is CancellationError {
            status = String(localized: "Cancelled. No completed snapshot was published.", table: "Backup")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseAndVerifySnapshot() async {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Verify Snapshot", table: "Backup")
        panel.prompt = String(localized: "Verify", table: "Backup")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        if let folderPath { panel.directoryURL = URL(fileURLWithPath: folderPath) }
        guard panel.runModal() == .OK, let snapshot = panel.url else { return }
        await verify(snapshot: snapshot)
    }

    func verify(snapshot: URL) async {
        guard !isBusy else { return }
        let token = begin()
        defer { finish() }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                let scoped = snapshot.startAccessingSecurityScopedResource()
                defer { if scoped { snapshot.stopAccessingSecurityScopedResource() } }
                return try MacBackupService.verify(snapshot: snapshot, cancellation: token)
            }.value
            status = String(localized: "Snapshot verified: checksums, audio references, and database integrity match. This does not verify cloud upload.", table: "Backup")
        } catch is CancellationError {
            status = String(localized: "Verification cancelled.", table: "Backup")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() { cancellation?.cancel() }

    private func begin() -> MacBackupCancellation {
        isBusy = true
        errorMessage = nil
        status = nil
        let token = MacBackupCancellation()
        cancellation = token
        return token
    }

    private func finish() {
        isBusy = false
        cancellation = nil
    }

    private func resolveFolder() throws -> URL {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            throw MacBackupError.unavailableFolder
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.checkResourceIsReachable() else { throw MacBackupError.unavailableFolder }
        if stale {
            let refreshed = try url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return url
    }
}
