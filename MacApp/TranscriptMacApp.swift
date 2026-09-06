import SwiftUI

@main
struct TranscriptMacApp: App {
    @State private var workspace = MacWorkspace()
    @AppStorage("mac.appearance") private var appearance = MacAppearance.system

    var body: some Scene {
        WindowGroup("app.name", id: "main") {
            MacThemedContent {
                MacRootView()
            }
            .environment(workspace)
            .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Audio…") {
                    workspace.showingImporter = true
                }
                .keyboardShortcut("o")
                .disabled(workspace.library.isImporting)
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(MacSection.allCases.enumerated()), id: \.element.id) { index, section in
                    Button(section.title) { workspace.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button(LocalizedStringKey(workspace.showingSamples ? "Return to My Library" : "Show Sample Library")) {
                    workspace.setSamples(!workspace.showingSamples)
                }
            }
        }

        Settings {
            MacThemedContent {
                MacSettingsView()
            }
            .environment(workspace)
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}
