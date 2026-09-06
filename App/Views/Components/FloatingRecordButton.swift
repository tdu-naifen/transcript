import SwiftUI

/// Position is stored as a fraction of the available center-to-center travel area.
/// Resizing changes that area, not the user's preferred relative position.
struct FloatingRecordButton: View {
    static let accent = Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255)
    private static let xKey = "floatingRecordButton.normalizedX"
    private static let yKey = "floatingRecordButton.normalizedY"

    @AppStorage(Self.xKey) private var normalizedX = 1.0
    @AppStorage(Self.yKey) private var normalizedY = 1.0
    @GestureState private var translation = CGSize.zero
    let action: () -> Void

    static func resetPosition() {
        UserDefaults.standard.set(1.0, forKey: xKey)
        UserDefaults.standard.set(1.0, forKey: yKey)
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = movementBounds(in: geometry)
            let origin = point(in: bounds)
            let position = clamped(
                CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                to: bounds
            )

            Image(systemName: "waveform")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: FloatingRecordButtonMetrics.diameter, height: FloatingRecordButtonMetrics.diameter)
                .background(Self.accent, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .named("floatingRecorderArea"))
                        .updating($translation) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            store(
                                CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height),
                                in: bounds
                            )
                        }
                        // A recognized drag consumes the touch even if it returns to its origin.
                        .exclusively(before: TapGesture().onEnded { action() })
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Record")
                .accessibilityHint("Drag to move the recording button, or use its movement actions.")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("globalRecordButton")
                .accessibilityAction { action() }
                .accessibilityAction(named: Text("Move recording button left")) { move(x: -0.15, y: 0) }
                .accessibilityAction(named: Text("Move recording button right")) { move(x: 0.15, y: 0) }
                .accessibilityAction(named: Text("Move recording button up")) { move(x: 0, y: -0.15) }
                .accessibilityAction(named: Text("Move recording button down")) { move(x: 0, y: 0.15) }
                .accessibilityAction(named: Text("Reset recording button position")) { Self.resetPosition() }
                .position(position)
        }
        .coordinateSpace(name: "floatingRecorderArea")
    }

    private func movementBounds(in geometry: GeometryProxy) -> CGRect {
        let radius = FloatingRecordButtonMetrics.diameter / 2
        let insets = geometry.safeAreaInsets
        let minX = min(geometry.size.width / 2, insets.leading + radius + 16)
        let maxX = max(minX, geometry.size.width - insets.trailing - radius - 16)
        let minY = min(geometry.size.height / 2, insets.top + radius + 16)
        let maxY = max(minY, geometry.size.height - insets.bottom - radius - FloatingRecordButtonMetrics.bottomPadding)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func fraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }

    private func point(in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.minX + bounds.width * fraction(normalizedX),
            y: bounds.minY + bounds.height * fraction(normalizedY)
        )
    }

    private func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
    }

    private func store(_ point: CGPoint, in bounds: CGRect) {
        let point = clamped(point, to: bounds)
        if bounds.width > 0 { normalizedX = (point.x - bounds.minX) / bounds.width }
        if bounds.height > 0 { normalizedY = (point.y - bounds.minY) / bounds.height }
    }

    private func move(x: Double, y: Double) {
        normalizedX = fraction(fraction(normalizedX) + x)
        normalizedY = fraction(fraction(normalizedY) + y)
    }
}
