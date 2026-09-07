import SwiftUI
import TranscriptCore

/// The caller supplies a locally pinned peer, never an identity from a payload.
struct AutomaticSyncSettingsView: View {
    let repository: AutomaticSyncRepository
    let peerID: String
    let setEnabled: @MainActor (Bool) async throws -> Void
    let setVoiceprintConsent: @MainActor (AutomaticSyncRepository.Wire.Consent) async throws -> Void
    @State private var status: AutomaticSyncRepository.Status?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var confirmingVoiceprints = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatic sync", tableName: "AutomaticSync").font(.headline)
            Text("Authorize only this trusted device. Both devices must enable sync. Connection, synchronization and model processing have separate states.", tableName: "AutomaticSync")
                .font(.caption).foregroundStyle(.secondary)
            if let status {
                Toggle(isOn: Binding(
                    get: { status.enabled },
                    set: { enabled in
                        save {
                            try await setEnabled(enabled)
                        }
                    }
                )) {
                    Text("Sync with this device", tableName: "AutomaticSync")
                }
                .accessibilityIdentifier("automaticSyncEnabled")
                Text("Enabling sync exchanges existing and future supported library changes over the authenticated local connection. Disabling pauses future transfer; it does not erase either library.", tableName: "AutomaticSync")
                    .font(.caption).foregroundStyle(.secondary)

                Text(consentKey(status.voiceprints), tableName: "AutomaticSync")
                    .accessibilityIdentifier("automaticSyncVoiceprintState")
                HStack {
                    if status.voiceprints != .allowed {
                        Button {
                            confirmingVoiceprints = true
                        } label: {
                            Text("Authorize voiceprints", tableName: "AutomaticSync")
                        }
                        .disabled(!status.enabled)
                        .accessibilityIdentifier("automaticSyncAuthorizeVoiceprints")
                    } else {
                        Button {
                            save { try await setVoiceprintConsent(.paused) }
                        } label: {
                            Text("Pause voiceprints", tableName: "AutomaticSync")
                        }
                    }
                    if status.voiceprints == .allowed || status.voiceprints == .paused {
                        Button(role: .destructive) {
                            save { try await setVoiceprintConsent(.revoked) }
                        } label: {
                            Text("Revoke voiceprints", tableName: "AutomaticSync")
                        }
                    }
                }
                Text("Pausing or revoking prevents future biometric transfer. Copies already received may remain on either device; this is not a remote erasure request.", tableName: "AutomaticSync")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
                Button { Task { await load() } } label: {
                    Text("Retry", tableName: "AutomaticSync")
                }
            }
        }
        .disabled(isSaving)
        .task(id: peerID) { await load() }
        .confirmationDialog(
            Text("Authorize voiceprints for this device?", tableName: "AutomaticSync"),
            isPresented: $confirmingVoiceprints,
            titleVisibility: .visible
        ) {
            Button {
                save { try await setVoiceprintConsent(.allowed) }
            } label: {
                Text("Authorize voiceprints", tableName: "AutomaticSync")
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", tableName: "AutomaticSync")
            }
        } message: {
            Text("Speaker identities, names, meeting associations and actual voiceprint artifacts are sensitive biometric data. Allow this paired device to send and receive them locally. No cloud upload is authorized.", tableName: "AutomaticSync")
        }
    }

    private func consentKey(_ consent: AutomaticSyncRepository.Wire.Consent) -> LocalizedStringKey {
        switch consent {
        case .denied: "Voiceprints not authorized"
        case .allowed: "Voiceprints authorized"
        case .paused: "Voiceprints paused"
        case .revoked: "Voiceprints revoked"
        }
    }

    @MainActor private func load() async {
        do {
            status = try await repository.status(peerID: peerID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func save(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await operation()
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
