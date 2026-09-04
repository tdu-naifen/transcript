import SwiftUI
import TranscriptCore

struct RootView: View {
    @State private var launch = LaunchState()
    private var localization: LocalizationManager { .shared }

    var body: some View {
        Group {
            switch launch.phase {
            case .loading:
                ProgressView().task { launch.load() }
            case .failed(let message):
                ContentUnavailableView(
                    "Transcript can't start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .ready(let services, let library, let recorder):
                ReadyView(services: services, library: library, recorder: recorder)
            }
        }
        // Reading `language` here registers Observation tracking, so every descendant
        // `Text`/`Label` (via `LocalizedStringKey`) re-renders in the new language the
        // instant Settings changes it — no app restart needed.
        .environment(\.locale, localization.language.locale ?? .autoupdatingCurrent)
    }
}

/// Geometry of the floating record button (UI.md §1), shared with `RecordingsListView`
/// so its list can reserve enough bottom inset to never be occluded by the button.
enum FloatingRecordButtonMetrics {
    static let diameter: CGFloat = 64
    static let bottomPadding: CGFloat = 58
    /// Clearance a scrollable list needs at its bottom edge: padding + button + margin.
    static let listBottomClearance: CGFloat = bottomPadding + diameter + 16
}

/// The recordings list is the home screen (UI.md §1): two tabs plus a record button that
/// belongs to neither and floats above the tab bar.
private struct ReadyView: View {
    let services: AppServices
    let library: LibraryModel
    let recorder: RecorderModel
    @State private var isRecordingExpanded = Self.debugRecordingExpanded
    @State private var selectedTab: AppTab = Self.debugInitialTab
    @State private var recordingsPath = NavigationPath()
    @State private var activeMeeting: Meeting?
    @State private var namingMeetingId: String?
    @State private var meetingName = ""
    @State private var defaultMeetingName = ""
    @State private var isMeetingNamingPresented = false

    /// Screenshot verification aid, same pattern as `-uiFixtureOpenMeetingId`: the
    /// simulator has no scripted-tap path to the Settings tab in this environment.
    private static var debugInitialTab: AppTab {
        #if DEBUG
        UserDefaults.standard.string(forKey: "uiFixtureSelectedTab") == "settings" ? .settings : .recordings
        #else
        .recordings
        #endif
    }

    private static var debugRecordingExpanded: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "uiFixtureExpandRecording")
        #else
        false
        #endif
    }

    /// The record button only makes sense on the recordings list and settings tabs
    /// (UI.md §1); on the meeting detail screen it's semantically wrong (that screen is
    /// for replaying a past meeting) and visually overlaps the audio player's controls.
    private var isFloatingButtonHidden: Bool {
        selectedTab == .recordings && !recordingsPath.isEmpty
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("录音", systemImage: "list.bullet", value: AppTab.recordings) {
                    RecordingsListView(
                        model: library,
                        services: services,
                        path: $recordingsPath,
                        isRecordingActive: { recorder.isActive }
                    )
                }
                Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                    SettingsView(services: services)
                }
            }

            if isRecordingExpanded {
                RecordView(
                    model: recorder,
                    onCollapse: { withAnimation(.snappy) { isRecordingExpanded = false } },
                    onStop: requestStop
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if recorder.isActive && !isRecordingExpanded {
                RecordingMiniBar(
                    model: recorder,
                    onExpand: { withAnimation(.snappy) { isRecordingExpanded = true } },
                    onStop: requestStop
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isFloatingButtonHidden && !recorder.isActive && !isRecordingExpanded {
                Button {
                    isRecordingExpanded = true
                    Task {
                        await recorder.onAppear()
                        await recorder.toggleRecording()
                    }
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: FloatingRecordButtonMetrics.diameter, height: FloatingRecordButtonMetrics.diameter)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                }
                .padding(.trailing, 20)
                .padding(.bottom, FloatingRecordButtonMetrics.bottomPadding)
                .accessibilityLabel("Record")
                .accessibilityIdentifier("globalRecordButton")
            }
        }
        .alert(acceptanceText("Confirm meeting name"), isPresented: $isMeetingNamingPresented) {
            TextField(acceptanceText("Meeting name"), text: $meetingName)
                .accessibilityIdentifier("meetingNameField")
            Button(acceptanceText("Keep Default"), role: .cancel) {}
            Button(acceptanceText("Save")) { saveMeetingName() }
                .accessibilityIdentifier("meetingNameSaveButton")
        } message: {
            Text(acceptanceText("Enter or confirm a name for this meeting."))
        }
        .onChange(of: recorder.phase) { oldPhase, newPhase in
            if newPhase == .recording || newPhase == .paused {
                Task { await captureActiveMeeting() }
            } else if newPhase == .stopping && oldPhase != .stopping {
                Task {
                    if activeMeeting == nil { await captureActiveMeeting() }
                    presentMeetingNaming()
                }
            } else if newPhase == .idle && oldPhase == .stopping {
                Task { await library.reload() }
            }
        }
    }

    private func requestStop() {
        if activeMeeting != nil {
            presentMeetingNaming()
            Task { await recorder.toggleRecording() }
        } else {
            Task {
                await captureActiveMeeting()
                presentMeetingNaming()
                await recorder.toggleRecording()
            }
        }
    }

    private func captureActiveMeeting() async {
        guard let id = await services.session.activeMeetingId else { return }
        activeMeeting = try? await MeetingRepository(services.database).fetch(id: id)
    }

    private func presentMeetingNaming() {
        guard !isMeetingNamingPresented, let meeting = activeMeeting else { return }
        namingMeetingId = meeting.id
        defaultMeetingName = meeting.title
        meetingName = meeting.title
        isMeetingNamingPresented = true
    }

    private func saveMeetingName() {
        guard let id = namingMeetingId else { return }
        let title = MeetingTitle.confirmedTitle(meetingName, defaultTitle: defaultMeetingName)
        Task {
            _ = try? await MeetingRepository(services.database).rename(
                id: id, title: title, deviceId: services.deviceId
            )
            await library.reload()
        }
    }

    private func acceptanceText(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            table: "AcceptanceUI",
            locale: LocalizationManager.shared.resolvedLocale
        )
    }
}

private struct RecordingMiniBar: View {
    let model: RecorderModel
    let onExpand: () -> Void
    let onStop: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.phase == .paused ? Color.secondary : Color.red)
                    .frame(width: 8, height: 8)
                Text(Format.clock(model.elapsed))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                LevelMeterView(level: model.level, isActive: model.phase == .recording)
                    .frame(maxWidth: .infinity)
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                .accessibilityIdentifier("miniStopButton")
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(.regularMaterial)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand recording")
        .accessibilityIdentifier("recordingMiniBar")
    }
}

private enum AppTab: Hashable {
    case recordings
    case settings
}

@MainActor
@Observable
private final class LaunchState {
    enum Phase {
        case loading
        case failed(String)
        case ready(AppServices, LibraryModel, RecorderModel)
    }

    var phase: Phase = .loading

    func load() {
        guard case .loading = phase else { return }
        do {
            let services = try AppServices()
            let library = LibraryModel(services: services)
            let recorder = RecorderModel(services: services, library: library)
            phase = .ready(services, library, recorder)
            #if DEBUG
            SmokeRecording.runIfRequested(recorder)
            Task { @MainActor in
                await UIFixture.seedIfRequested(services: services)
                await library.reload()
            }
            #endif
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

#if DEBUG
/// Drives one whole recording from a launch argument, so the capture → seal path can be
/// exercised in the simulator without UI automation:
/// `xcrun simctl launch booted com.transcript.Transcript -smokeRecordSeconds 4`
enum SmokeRecording {
    static func runIfRequested(_ recorder: RecorderModel) {
        let seconds = UserDefaults.standard.double(forKey: "smokeRecordSeconds")
        guard seconds > 0 else { return }
        Task { @MainActor in
            await recorder.onAppear()
            await recorder.toggleRecording()
            try? await Task.sleep(for: .seconds(seconds))
            await recorder.toggleRecording()
        }
    }
}
#endif

#Preview {
    RootView()
}
