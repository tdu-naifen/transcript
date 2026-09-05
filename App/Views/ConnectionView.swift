import SwiftUI

struct ConnectionView: View {
    let model: MacConnectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var startedPairingHere = false
    @State private var confirmsUnpairing = false

    var body: some View {
        List {
            Section {
                ConnectionStatusLabel(model: model)
                Text(model.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("macConnectionExplanation")
            }

            if !model.isConnected {
                Section {
                    Label("Open Transcript on your Mac", systemImage: "desktopcomputer")
                    Text("Transcript uses your local network to discover your Mac and transfer meeting audio and results. iOS may ask for local network access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(action: { perform(.discover) }) {
                        Label("Find a Mac", systemImage: "magnifyingglass")
                            .frame(minHeight: 32)
                    }
                    .disabled(!model.hasTransportActions || model.pendingAction != nil || model.isConnecting || isPairing)
                    .accessibilityIdentifier("macFindDevicesButton")
                } header: {
                    Text("Pair with your Mac")
                }
            }

            if case .discovering = model.connection {
                Section("Nearby Macs") {
                    if model.devices.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for a Mac")
                        }
                    } else {
                        ForEach(model.devices) { device in
                            Button {
                                startedPairingHere = true
                                perform(.selectDevice(device.id))
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    VStack(alignment: .leading) {
                                        Text(verbatim: device.name)
                                        Text(verbatim: device.id)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(!model.hasTransportActions || model.pendingAction != nil)
                            .accessibilityIdentifier("macDiscoveredDevice_\(device.id)")
                        }
                    }
                }
            }

            if case .pairing(let pairing) = model.connection {
                Section("Confirm pairing") {
                    Text(verbatim: pairing.device.name)
                        .font(.headline)
                    Text(verbatim: pairing.code)
                        .font(.largeTitle.monospacedDigit().bold())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                        .accessibilityLabel(Text("Pairing code"))
                        .accessibilityValue(pairing.code.map(String.init).joined(separator: " "))
                        .accessibilityIdentifier("macPairingCode")
                    Label {
                        Text(MacConnectionModel.text(pairing.confirmedOnPhone ? "Confirmed on iPhone" : "Waiting for iPhone confirmation"))
                    } icon: {
                        Image(systemName: pairing.confirmedOnPhone ? "checkmark.circle" : "circle")
                    }
                    Label {
                        Text(MacConnectionModel.text(pairing.confirmedOnMac ? "Confirmed on Mac" : "Waiting for Mac confirmation"))
                    } icon: {
                        Image(systemName: pairing.confirmedOnMac ? "checkmark.circle" : "circle")
                    }
                    Button("The codes match") {
                        startedPairingHere = true
                        perform(.confirmPairing)
                    }
                    .disabled(pairing.confirmedOnPhone || !model.hasTransportActions || model.pendingAction != nil)
                    .accessibilityIdentifier("macConfirmPairingButton")
                }
            }

            if canRetryConnection {
                Section {
                    Button("Retry connection") { perform(.retryConnection) }
                        .disabled(!model.hasTransportActions || model.pendingAction != nil)
                        .accessibilityIdentifier("macRetryConnectionButton")
                }
            }

            if canUnpair {
                Section {
                    Button("Unpair Mac", role: .destructive) { confirmsUnpairing = true }
                        .disabled(!model.hasTransportActions || model.pendingAction != nil)
                        .accessibilityIdentifier("macUnpairButton")
                }
            }

            if let error = model.actionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("macConnectionError")
                }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .tint(Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255))
        .onChange(of: model.isConnected) { wasConnected, isConnected in
            // Only a pairing started on this screen may automatically navigate back.
            // A background reconnect must not disrupt the user's current navigation.
            if !wasConnected && isConnected && startedPairingHere { dismiss() }
        }
        .confirmationDialog("Unpair Mac?", isPresented: $confirmsUnpairing, titleVisibility: .visible) {
            Button("Unpair Mac", role: .destructive) { perform(.unpair) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to confirm both devices again before reconnecting. This does not delete meetings.")
        }
    }

    private var isPairing: Bool {
        if case .pairing = model.connection { return true }
        return false
    }

    private var canRetryConnection: Bool {
        switch model.connection {
        case .offline, .failed: return true
        default: return false
        }
    }

    private var canUnpair: Bool {
        switch model.connection {
        case .offline, .connected: return true
        default: return false
        }
    }

    private func perform(_ action: MacConnectionModel.Action) {
        Task { await model.perform(action) }
    }
}

/// Compact Home navigation label. Color always accompanies a readable state.
struct ConnectionStatusLabel: View {
    let model: MacConnectionModel

    var body: some View {
        HStack(spacing: 6) {
            if model.isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let device = model.device {
                    Text(verbatim: device.name)
                        .lineLimit(1)
                }
                Text(MacConnectionModel.text(model.statusKey))
                    .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("macConnectionStatus")
    }
}

/// Non-blocking task presentation for Home or a meeting detail. Leaving it does
/// not cancel work: all actions and observed jobs belong to the upstream service.
struct MacTaskStatusView: View {
    let model: MacConnectionModel
    var meetingID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.jobs.filter { meetingID == nil || $0.meetingID == meetingID }) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: job.meetingTitle)
                        .font(.headline)
                    Text(MacConnectionModel.text(job.statusKey))
                        .accessibilityIdentifier("macTaskState_\(job.id)")
                    if !model.isConnected && !job.isFinished {
                        Text("Mac offline · Showing last known progress")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if case .failed(let reason) = job.phase {
                        Text(verbatim: reason)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if job.cancellation == .requested {
                        Text("Cancellation requested · Waiting for Mac confirmation")
                            .font(.footnote)
                    } else if job.cancellation == .tooLate {
                        Text("Mac could not cancel because the task had already finished.")
                            .font(.footnote)
                    }
                    HStack {
                        if !job.isFinished && job.cancellation == .none {
                            Button("Request cancellation", role: .destructive) {
                                Task { await model.perform(.requestCancellation(job.id)) }
                            }
                            .accessibilityIdentifier("macCancelTask_\(job.id)")
                        }
                        if job.phase == .awaitingReconnect && job.cancellation == .none {
                            Button("Retry sending") {
                                Task { await model.perform(.retryTask(job.id)) }
                            }
                            .disabled(!model.isConnected)
                            .accessibilityIdentifier("macRetryTask_\(job.id)")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasTransportActions || model.pendingAction != nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityElement(children: .contain)
            }
            if let error = model.actionError {
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityIdentifier("macTaskStatus")
    }
}
