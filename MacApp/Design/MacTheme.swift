import SwiftUI

enum MacAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum MacTheme {
    // Match the shipping iPhone palette without changing its target or theme.
    static let brand = Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255)

    static func tint(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        guard scheme == .dark else { return brand }
        return contrast == .increased
            ? Color(red: 195 / 255, green: 212 / 255, blue: 1)
            : Color(red: 144 / 255, green: 174 / 255, blue: 1)
    }

    static func settingsBackground(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: .windowBackgroundColor)
            : Color(red: 0.975, green: 0.97, blue: 0.96)
    }

    static func speaker(_ index: Int) -> Color {
        let palette: [Color] = [
            .red, .orange, .yellow, .green, .mint, .teal,
            .cyan, .blue, .indigo, .purple, .pink, .brown
        ]
        return palette[((index % palette.count) + palette.count) % palette.count]
    }
}

struct MacBrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(MacTheme.brand, in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
    }
}

struct MacThemedContent<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .tint(MacTheme.tint(scheme: scheme, contrast: contrast))
    }
}

struct MacSelectionRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MacTheme.tint(scheme: scheme, contrast: contrast).opacity(0.15))
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum MacListSelection {
    static func moved<ID: Equatable>(_ selection: ID?, in ids: [ID], direction: MoveCommandDirection) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard direction == .up || direction == .down else { return selection }
        guard let selection, let index = ids.firstIndex(of: selection) else { return ids.first }
        return ids[min(max(index + (direction == .down ? 1 : -1), 0), ids.count - 1)]
    }
}

struct MacStatusLabel: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Circle().fill(color).frame(width: 7, height: 7)
        }

        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

struct MacPhoneConnectionIcon: View {
    let isConnected: Bool
    let isWorking: Bool
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "iphone")
            .font(.system(size: size, weight: .light))
            .padding(.trailing, 5)
            .overlay(alignment: .topTrailing) {
                Circle().fill(isConnected ? Color.green : .red)
                    .frame(width: size > 30 ? 12 : 7, height: size > 30 ? 12 : 7)
            }
            .overlay(alignment: .bottomTrailing) {
                if isWorking {
                    ProgressView().controlSize(.mini)
                }
            }
            .accessibilityHidden(true)
    }
}
