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
            TabView {
                Tab("Home", systemImage: "waveform") {
                    RecordView(model: recorder)
                }
                Tab("Recordings", systemImage: "list.bullet") {
                    RecordingsListView(model: library)
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsView(deviceId: services.deviceId, audioDirectory: services.store.directory)
                }
            }
        }
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
