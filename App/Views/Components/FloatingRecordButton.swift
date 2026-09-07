import SwiftUI

/// The global entry point lives in the bottom dock, never over scrollable content.
struct FloatingRecordButton: View {
    static let accent = Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255)
    static let diameter: CGFloat = 56
    static let xKey = "floatingRecordButton.normalizedX"
    static let yKey = "floatingRecordButton.normalizedY"

    var hasRecordingSession = false
    var isExpanded = false
    let action: () -> Void

    static func resetPosition(defaults: UserDefaults = .standard) {
        defaults.set(1.0, forKey: xKey)
        defaults.set(1.0, forKey: yKey)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: hasRecordingSession ? "waveform" : "mic.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Self.accent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(hasRecordingSession
            ? (isExpanded ? "Collapse recording" : "Expand recording") : "Record"))
        .accessibilityIdentifier("globalRecordButton")
    }
}
