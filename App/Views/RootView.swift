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
        .environment(\.locale, localization.resolvedLocale)
        .tint(AppColors.controlTint)
        .modifier(ForegroundIdleTimerLifecycle())
        #if DEBUG
        .preferredColorScheme(fixtureColorScheme)
        #endif
    }

    #if DEBUG
    private var fixtureColorScheme: ColorScheme? {
        guard UIFixture.isRequested else { return nil }
        switch UserDefaults.standard.string(forKey: "uiFixtureAppearance") {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
    #endif
}

struct MacConnectionSceneLifecycle: ViewModifier {
    let model: MacConnectionModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { model.suspendConnection() }
            if phase == .active { model.resumeConnection() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            model.suspendConnection()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            if scenePhase == .active { model.resumeConnection() }
        }
    }
}

/// Retained as the shared list-clearance contract; controls now reserve a safe area.
enum FloatingRecordButtonMetrics {
    static let listBottomClearance: CGFloat = 0
}

/// Each tab keeps its own navigation history; the recorder belongs to the app, not a tab.
private struct ReadyView: View {
    let services: AppServices
    let library: LibraryModel
    let recorder: RecorderModel
    @State private var isRecordingExpanded = Self.debugRecordingExpanded
    @State private var selectedTab: AppTab = Self.debugInitialTab
    @State private var homePath = NavigationPath()
    @State private var recordingsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var macConnection = MacConnectionModel(discovery: BonjourMacDiscovery())
    @Environment(\.scenePhase) private var scenePhase
    @State private var startGate = UIActionGate()
    @State private var stopGate = UIActionGate()
    @State private var pauseGate = UIActionGate()
    @State private var namingError: String?
    @State private var namingMeetingId: String?
    @State private var lastNamedMeetingId: String?
    @State private var meetingName = ""
    @State private var defaultMeetingName = ""
    @State private var isMeetingNamingPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var debugInitialTab: AppTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "uiFixtureSelectedTab") {
        case "settings": return .settings
        case "recordings", "meetings": return .meetings
        case "home": return .home
        default:
            // Preserve existing detail-fixture launch arguments while Home is the default.
            return UserDefaults.standard.string(forKey: "uiFixtureOpenMeetingId") == nil ? .home : .meetings
        }
        #else
        return .home
        #endif
    }

    private static var debugRecordingExpanded: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "uiFixtureExpandRecording")
        #else
        false
        #endif
    }

    private var isFloatingButtonHidden: Bool {
        switch selectedTab {
        case .home: !homePath.isEmpty
        case .meetings: !recordingsPath.isEmpty
        case .settings: !settingsPath.isEmpty
        }
    }

    private var hasRecordingSession: Bool {
        recorder.phase != .idle || isStartingRecording
    }

    private var isStartingRecording: Bool { startGate.isRunning }
    private var isStoppingRecording: Bool { stopGate.isRunning }

    private var isCaptureActive: Bool {
        services.audioOwnership.isCaptureReserved || isStartingRecording
            || recorder.phase == .starting || recorder.isActive || recorder.phase == .stopping
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab(LocalizationManager.shared.text("Home"), systemImage: "house", value: AppTab.home) {
                    HomeView(
                        services: services,
                        library: library,
                        path: $homePath,
                        isRecordingActive: { isCaptureActive },
                        macConnection: macConnection
                    )
                    .toolbar(.hidden, for: .tabBar)
                }
                Tab(LocalizationManager.shared.text("Meetings"), systemImage: "list.bullet", value: AppTab.meetings) {
                    RecordingsListView(
                        model: library,
                        services: services,
                        path: $recordingsPath,
                        isRecordingActive: { isCaptureActive },
                        macConnection: macConnection
                    )
                    .toolbar(.hidden, for: .tabBar)
                }
                Tab(LocalizationManager.shared.text("Settings"), systemImage: "gearshape", value: AppTab.settings) {
                    SettingsView(services: services, path: $settingsPath)
                        .toolbar(.hidden, for: .tabBar)
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isRecordingExpanded && (!isFloatingButtonHidden || hasRecordingSession) {
                    bottomDock
                }
            }
            .accessibilityHidden(isRecordingExpanded)
            .allowsHitTesting(!isRecordingExpanded)

            if isRecordingExpanded {
                RecordView(
                    model: recorder,
                    onCollapse: { isRecordingExpanded = false },
                    onStop: requestStop,
                    onStart: startRecording,
                    onPause: requestPause,
                    isStartingRecording: isStartingRecording,
                    areControlsBusy: isStoppingRecording || pauseGate.isRunning
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomDock
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: isRecordingExpanded)
        .task {
            macConnection.enablePairing()
            macConnection.installAutomaticSync(database: services.database, audioDirectory: services.store.directory)
            await macConnection.enableMeetingCopies(database: services.database, store: services.store)
        }
        .task { await recorder.onAppear() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            services.speakerAnalysis.setActive(phase == .active)
            recorder.sceneActivityChanged(isActive: phase == .active)
        }
        .modifier(MacConnectionSceneLifecycle(model: macConnection))
        .onChange(of: services.speakerAnalysis.revision) { _, _ in
            Task { await library.reload() }
        }
        .alert(acceptanceText("Confirm meeting name"), isPresented: $isMeetingNamingPresented) {
            TextField(acceptanceText("Meeting name"), text: $meetingName)
                .accessibilityIdentifier("meetingNameField")
            Button(acceptanceText("Save")) { saveMeetingName() }
                .accessibilityIdentifier("meetingNameSaveButton")
                .disabled(meetingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(acceptanceText("Enter or confirm a name for this meeting."))
        }
        .alert("Could not save meeting name", isPresented: Binding(
            get: { namingError != nil },
            set: { if !$0 { namingError = nil } }
        )) {
            Button("Retry") { saveMeetingName() }
            Button("Cancel", role: .cancel) { namingError = nil }
        } message: {
            Text(namingError ?? "")
        }
        .alert("Recording problem", isPresented: Binding(
            get: { !isRecordingExpanded && recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
        .onChange(of: recorder.phase) { oldPhase, newPhase in
            if newPhase == .idle && oldPhase == .stopping {
                isRecordingExpanded = false
                Task { await library.reload() }
            }
        }
        .onChange(of: recorder.lastArchivedMeeting) { _, archived in
            guard let archived else { return }
            isRecordingExpanded = false
            presentMeetingNaming(archived)
            Task { await library.reload() }
        }
    }

    private var bottomDock: some View {
        VStack(spacing: 8) {
            if hasRecordingSession && !isRecordingExpanded {
                RecordingMiniBar(
                    model: recorder,
                    onExpand: { isRecordingExpanded = true },
                    onStop: requestStop,
                    onPause: requestPause,
                    areControlsBusy: isStoppingRecording || pauseGate.isRunning
                )
            }
            HStack(spacing: 12) {
                RecordingDockTabs(selection: Binding(
                    get: { selectedTab },
                    set: {
                        selectedTab = $0
                        isRecordingExpanded = false
                    }
                ))
                    .frame(height: 56)
                if (hasRecordingSession || !isFloatingButtonHidden) && !isMeetingNamingPresented {
                    FloatingRecordButton(hasRecordingSession: hasRecordingSession, isExpanded: isRecordingExpanded) {
                        if hasRecordingSession { isRecordingExpanded.toggle() }
                        else { startRecording() }
                    }
                    .disabled(!hasRecordingSession && (!recorder.canStartRecording || isStoppingRecording))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func requestPause() {
        guard recorder.isActive, !isStoppingRecording, pauseGate.begin() else { return }
        Task {
            defer { pauseGate.finish() }
            await recorder.togglePause()
        }
    }

    private func startRecording() {
        // Permission and startup both suspend before the model necessarily becomes busy.
        // Lock the root entry synchronously so a second tap cannot toggle the new session off.
        guard recorder.canStartRecording, !isStoppingRecording, startGate.begin() else { return }
        isRecordingExpanded = true
        Task {
            defer { startGate.finish() }
            await recorder.onAppear()
            guard recorder.canStartRecording else { return }
            await recorder.toggleRecording()
        }
    }

    private func requestStop() {
        guard recorder.isActive, !pauseGate.isRunning, stopGate.begin() else { return }
        Task {
            defer { stopGate.finish() }
            // Capture must stop regardless of whether the naming alert is completed.
            guard recorder.isActive else { return }
            await recorder.toggleRecording()
        }
    }

    private func presentMeetingNaming(_ meeting: Meeting) {
        guard !isMeetingNamingPresented, lastNamedMeetingId != meeting.id else { return }
        lastNamedMeetingId = meeting.id
        namingMeetingId = meeting.id
        defaultMeetingName = meeting.title
        meetingName = meeting.title
        isMeetingNamingPresented = true
    }

    private func saveMeetingName() {
        guard let id = namingMeetingId else { return }
        let title = MeetingTitle.confirmedTitle(meetingName, defaultTitle: defaultMeetingName)
        namingError = nil
        Task {
            do {
                _ = try await MeetingRepository(services.database).rename(
                    id: id, title: title, deviceId: services.deviceId
                )
                await library.reload()
            } catch {
                namingError = String(describing: error)
            }
        }
    }

    private func acceptanceText(_ key: String) -> String {
        LocalizationManager.shared.text(key, table: "AcceptanceUI")
    }
}

private struct RecordingMiniBar: View {
    let model: RecorderModel
    let onExpand: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let areControlsBusy: Bool

    private var statusLabel: String {
        model.stateLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onExpand) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(model.isActive && model.phase != .paused ? Color.red : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(Format.clock(model.elapsed))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    if model.isBusy {
                        ProgressView()
                        Text(statusLabel).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LevelMeterView(level: model.level, isActive: model.phase == .recording)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Expand recording")
            .accessibilityValue("\(statusLabel), \(Format.clock(model.elapsed))")
            .accessibilityIdentifier("recordingMiniBar")

            PauseButton(isPaused: model.phase == .paused, diameter: 44, action: onPause)
                .disabled(!model.isActive || areControlsBusy)
                .accessibilityIdentifier("miniPauseButton")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.red, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!model.isActive || areControlsBusy)
            .accessibilityLabel("Stop recording")
            .accessibilityIdentifier("miniStopButton")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private enum AppTab: Hashable {
    case home
    case meetings
    case settings
}

/// A native tab bar shares the bottom row with the separate recording action.
private struct RecordingDockTabs: UIViewRepresentable {
    @Binding var selection: AppTab
    private let tabs: [AppTab] = [.home, .meetings, .settings]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UITabBar {
        let bar = DockTabBar()
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.selection = $selection
        let titles = ["Home", "Meetings", "Settings"].map { LocalizationManager.shared.text($0) }
        if bar.items?.map(\.title) != titles.map(Optional.some) {
            bar.items = zip(titles, ["house", "list.bullet", "gearshape"]).enumerated().map { index, item in
                UITabBarItem(title: item.0, image: UIImage(systemName: item.1), tag: index)
            }
        }
        bar.tintColor = UIColor(AppColors.controlTint)
        bar.selectedItem = bar.items?[tabs.firstIndex(of: selection) ?? 0]
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<AppTab>
        init(selection: Binding<AppTab>) { self.selection = selection }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            let tabs: [AppTab] = [.home, .meetings, .settings]
            guard tabs.indices.contains(item.tag) else { return }
            selection.wrappedValue = tabs[item.tag]
        }
    }

    private final class DockTabBar: UITabBar {
        // SwiftUI already places this row above the home-indicator safe area.
        override var safeAreaInsets: UIEdgeInsets { .zero }
    }
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
