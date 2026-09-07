import SwiftUI

struct MacBackupSettingsView: View {
    let contextProvider: @MainActor () async throws -> MacLibraryContext
    @State private var controller = MacBackupController()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(localized: "Backup Folder", table: "Backup"), systemImage: "externaldrive")
                .font(.headline)
            Text(String(localized: "Choose a folder on a local drive, external drive, or iCloud Drive. Only backup snapshots are copied there; the working database and audio stay on this Mac.", table: "Backup"))
                .foregroundStyle(.secondary)
            if let path = controller.folderPath {
                Text(path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "No backup folder selected.", table: "Backup"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(String(localized: "Choose Folder…", table: "Backup")) {
                    Task { await controller.chooseFolder(contextProvider: contextProvider) }
                }
                .disabled(controller.isBusy)
                Button(String(localized: "Back Up Now", table: "Backup")) {
                    Task { await controller.backup(contextProvider: contextProvider) }
                }
                .disabled(controller.isBusy || !controller.hasFolder)
                .accessibilityIdentifier("macBackUpNow")
                Button(String(localized: "Verify Snapshot…", table: "Backup")) {
                    Task { await controller.chooseAndVerifySnapshot() }
                }
                .disabled(controller.isBusy)
            }
            if controller.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Working…", table: "Backup"))
                    Button(String(localized: "Cancel", table: "Backup")) { controller.cancel() }
                }
                .accessibilityElement(children: .contain)
            }
            if let status = controller.status {
                Text(status).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let snapshot = controller.lastSnapshot {
                Text(snapshot.lastPathComponent).font(.caption).textSelection(.enabled)
            }
            Divider()
            Label(String(localized: "Privacy and retention", table: "Backup"), systemImage: "lock.shield")
                .font(.subheadline.bold())
            Text(String(localized: "Snapshots are not encrypted by this app. They include recordings, transcripts, speaker identities, and potentially biometric voiceprint vectors. Protect the destination and its sharing permissions. Model weights and pairing keys are not exported.", table: "Backup"))
            Text(String(localized: "Choosing iCloud Drive delegates upload to macOS. A locally completed backup does not mean it has uploaded to iCloud or is available on another device.", table: "Backup"))
            Text(String(localized: "Historical snapshots retain deleted recordings, transcripts, and voiceprints until you remove those snapshots yourself. This app never automatically deletes old backups.", table: "Backup"))
            Text(String(localized: "Completed local ASR versions are included; unfinished jobs and temporary inputs are excluded.", table: "Backup"))
            Text(String(localized: "Restore is unavailable. Verification is read-only and does not restore data or alter the working library.", table: "Backup"))
                .fontWeight(.medium)
                .accessibilityIdentifier("macBackupRestoreUnavailable")
        }
        .font(.callout)
        .tint(MacTheme.tint(scheme: scheme, contrast: contrast))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
