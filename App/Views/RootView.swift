import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "waveform") {
                PlaceholderView(title: "Home")
            }
            Tab("Recordings", systemImage: "list.bullet") {
                PlaceholderView(title: "Recordings")
            }
            Tab("Settings", systemImage: "gearshape") {
                PlaceholderView(title: "Settings")
            }
        }
    }
}

private struct PlaceholderView: View {
    let title: String

    var body: some View {
        NavigationStack {
            Text(title)
                .font(.title2)
                .foregroundStyle(.secondary)
                .navigationTitle(title)
        }
    }
}

#Preview {
    RootView()
}
