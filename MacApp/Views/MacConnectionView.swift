import AppKit
import SwiftUI

struct MacConnectionView: View {
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var settingsError: String?
    @State private var peerToUnpair: MacPairedDevice?

    private var service: MacBonjourService { workspace.bonjour }
    private var tint: Color { MacTheme.tint(scheme: scheme, contrast: contrast) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("BETTER TOGETHER").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Bonjour · Local network").font(.caption).foregroundStyle(.secondary)
                }
                Text("Start on iPhone. Continue on Mac.")
                    .font(.system(size: 27, weight: .semibold))
                Text("Make this Mac discoverable to Transcript on your iPhone.")
                    .foregroundStyle(.secondary)
                VStack(spacing: 23) {
                    HStack(spacing: 25) {
                        Image(systemName: "iphone").font(.system(size: 52, weight: .ultraLight))
                        Image(systemName: "ellipsis").font(.title)
                        Image(systemName: "desktopcomputer").font(.system(size: 60, weight: .ultraLight))
                    }
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                    Text(statusTitle).font(.title2.weight(.semibold))
                        .accessibilityIdentifier("macBonjourStatus")
                    Text(service.advertisedName ?? service.serviceName)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(tint)
                        .textSelection(.enabled)
                    controls
                    MacStatusLabel(
                        title: service.pairing.connectedPeer == nil ? "Not connected" : "Authenticated connection",
                        color: service.pairing.connectedPeer == nil ? .orange : .green
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(30)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                if let failure {
                    MacInfoCard {
                        Label("Discovery needs attention", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(failure.message).foregroundStyle(.secondary).textSelection(.enabled)
                        if service.localNetworkDenied {
                            Button("Open Local Network Settings") { openNetworkSettings() }
                        }
                    }
                }
                pairingControls
                instruction(1, title: "Open Transcript on your iPhone",
                            detail: "Go to Home → Connection and choose Find a Mac. Keep Wi-Fi enabled on both devices.")
                instruction(2, title: "Select this Mac",
                            detail: "Compare all six digits on both devices. Only approve if they match, then confirm on your iPhone too.")
                MacInfoCard {
                    Label("Encrypted pairing. Your library stays private.", systemImage: "lock.shield")
                        .font(.headline)
                    Text("Trusted device identities are stored in Keychain. Reconnection verifies the saved identity without asking you to compare another code.")
                        .foregroundStyle(.secondary)
                    Text("Meeting transfer is not available in this version. No audio, transcripts or meeting metadata are sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MacInfoCard {
                    Label {
                        Text("Two separate macOS network permissions", tableName: "Pairing")
                    } icon: {
                        Image(systemName: "network")
                    }
                    .font(.headline)
                    Text("If your iPhone finds this Mac but no pairing code appears, check for a macOS prompt asking whether Transcript may accept incoming network connections. Allow incoming connections only if you intend to pair.", tableName: "Pairing")
                        .foregroundStyle(.secondary)
                    Text("Local Network access is under System Settings → Privacy & Security → Local Network. Incoming connections are controlled separately under Network → Firewall → Options. Allow this app rather than disabling the firewall.", tableName: "Pairing")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text("Discovery stays active while this app runs, even if you close the window. Stop discovery here or quit the app to withdraw the service.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Connection")
        .alert("Unable to open System Settings", isPresented: Binding(
            get: { settingsError != nil },
            set: { if !$0 { settingsError = nil } }
        )) {
            Button("OK") { settingsError = nil }
        } message: {
            Text(settingsError ?? "")
        }
        .confirmationDialog("Unpair this device?", isPresented: Binding(
            get: { peerToUnpair != nil },
            set: { if !$0 { peerToUnpair = nil } }
        )) {
            Button("Unpair", role: .destructive) {
                if let peerToUnpair { service.pairing.unpair(peerToUnpair) }
                peerToUnpair = nil
            }
            Button("Cancel", role: .cancel) { peerToUnpair = nil }
        } message: {
            Text("This device will need a new code comparison to connect. Your saved meetings are not deleted.")
        }
    }

    @ViewBuilder private var pairingControls: some View {
        if let confirmation = service.pairing.confirmation {
            MacInfoCard {
                Label("Compare pairing codes", systemImage: "lock.shield").font(.headline)
                Text("Pair with \(confirmation.name)?").textSelection(.enabled)
                Text(confirmation.code)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .tracking(6)
                    .accessibilityIdentifier("macPairingCode")
                Text("Check that these exact six digits appear on your iPhone. Confirm on BOTH devices. If they differ, reject.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Codes Match") { service.pairing.confirm(requestID: confirmation.id) }
                        .buttonStyle(MacBrandButtonStyle())
                        .disabled(service.pairing.localApproved)
                        .accessibilityIdentifier("macConfirmPairing")
                    Button("Reject", role: .destructive) { service.pairing.reject(requestID: confirmation.id) }
                        .accessibilityIdentifier("macRejectPairing")
                }
                Text(service.pairing.localApproved
                     ? "Approved on this Mac. Waiting for your iPhone…"
                     : "Waiting for approval on both devices. This request expires after 60 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if case .negotiating = service.pairing.state {
            HStack {
                ProgressView().controlSize(.small)
                Text("Verifying encrypted connection…")
                Button("Cancel") { service.pairing.disconnect() }
            }
        } else if let peer = service.pairing.connectedPeer {
            MacInfoCard {
                Label("Connected to \(peer.name)", systemImage: "checkmark.shield").font(.headline)
                Text("Identity verified · \(peer.fingerprint)").font(.caption).foregroundStyle(.secondary)
                Button("Disconnect") { service.pairing.disconnect() }
            }
        }
        if case .failed(let message) = service.pairing.state {
            Label(message, systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                .accessibilityIdentifier("macPairingError")
        }
        if service.state == .advertising, service.pairing.confirmation == nil,
           service.pairing.connectedPeer == nil {
            HStack {
                Text(service.pairing.allowsNewPairing
                     ? "New pairing is enabled for up to two minutes."
                     : "New pairing is disabled. Trusted devices can reconnect.")
                    .font(.caption).foregroundStyle(.secondary)
                if !service.pairing.allowsNewPairing {
                    Button("Enable Pairing") { service.pairing.enablePairing() }
                        .accessibilityIdentifier("macEnablePairing")
                }
            }
        }
        if !service.pairing.peers.isEmpty {
            MacInfoCard {
                Text("Trusted devices").font(.headline)
                ForEach(service.pairing.peers) { peer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text(peer.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unpair", role: .destructive) { peerToUnpair = peer }
                    }
                }
            }
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch service.state {
        case .idle: "Connect your iPhone"
        case .starting: "Starting discovery…"
        case .advertising: "Visible to your iPhone"
        case .waiting: "Waiting for the network"
        case .failed: "Discovery unavailable"
        }
    }

    private var failure: MacBonjourService.Failure? {
        switch service.state {
        case .waiting(let failure), .failed(let failure): failure
        default: nil
        }
    }

    @ViewBuilder private var controls: some View {
        switch service.state {
        case .idle:
            Button("Make This Mac Discoverable") { service.start() }
                .buttonStyle(MacBrandButtonStyle())
                .accessibilityIdentifier("macStartDiscovery")
        case .starting:
            HStack {
                ProgressView().controlSize(.small)
                Button("Stop Discovery") { service.stop() }
            }
        case .advertising:
            HStack {
                MacStatusLabel(title: "Advertising service", color: .green)
                Button("Stop Discovery") { service.stop() }
                    .accessibilityIdentifier("macStopDiscovery")
            }
        case .waiting, .failed:
            HStack {
                Button("Retry") { service.retry() }.buttonStyle(MacBrandButtonStyle())
                Button("Stop Discovery") { service.stop() }
            }
        }
    }

    private func instruction(_ number: Int, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number, format: .number)
                .font(.caption.weight(.semibold))
                .frame(width: 25, height: 25)
                .foregroundStyle(tint)
                .background(tint.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    private func openNetworkSettings() {
        let destination = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
        if !NSWorkspace.shared.open(destination) {
            settingsError = String(localized: "Open System Settings → Privacy & Security → Local Network, then enable Transcript.")
        }
    }

}
