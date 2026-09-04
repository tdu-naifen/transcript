import SwiftUI
import TranscriptCore

struct RootView: View {
    @State private var launch = LaunchState()

    var body: some View {
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
    @State private var isRecordingPresented = false
    @State private var selectedTab: AppTab = .recordings
    @State private var recordingsPath = NavigationPath()

    /// The record button only makes sense on the recordings list and settings tabs
    /// (UI.md §1); on the meeting detail screen it's semantically wrong (that screen is
    /// for replaying a past meeting) and visually overlaps the audio player's controls.
    private var isFloatingButtonHidden: Bool {
        selectedTab == .recordings && !recordingsPath.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                Tab("录音", systemImage: "list.bullet", value: AppTab.recordings) {
                    RecordingsListView(model: library, services: services, path: $recordingsPath)
                }
                Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                    SettingsView(services: services)
                }
            }

            if !isFloatingButtonHidden {
                Button {
                    isRecordingPresented = true
                } label: {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white, .red)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(width: FloatingRecordButtonMetrics.diameter, height: FloatingRecordButtonMetrics.diameter)
                }
                .padding(.trailing, 20)
                .padding(.bottom, FloatingRecordButtonMetrics.bottomPadding)
                .accessibilityLabel("Record")
            }
        }
        .fullScreenCover(isPresented: $isRecordingPresented) {
            RecordView(model: recorder)
        }
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
