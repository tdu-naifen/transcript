import SwiftUI

/// Position is stored as a fraction of the available center-to-center travel area.
/// Resizing changes that area, not the user's preferred relative position.
struct FloatingRecordButton: View {
    static let accent = Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255)
    static let xKey = "floatingRecordButton.normalizedX"
    static let yKey = "floatingRecordButton.normalizedY"

    @AppStorage(Self.xKey) private var normalizedX = 1.0
    @AppStorage(Self.yKey) private var normalizedY = 1.0
    @GestureState private var translation = CGSize.zero
    let action: () -> Void

    static func resetPosition(defaults: UserDefaults = .standard) {
        defaults.set(1.0, forKey: xKey)
        defaults.set(1.0, forKey: yKey)
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = FloatingRecordButtonGeometry.bounds(size: geometry.size, insets: geometry.safeAreaInsets)
            let origin = FloatingRecordButtonGeometry.point(normalized: normalizedPosition, in: bounds)
            let position = FloatingRecordButtonGeometry.clamped(
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

    private var normalizedPosition: CGPoint { CGPoint(x: normalizedX, y: normalizedY) }

    private func store(_ point: CGPoint, in bounds: CGRect) {
        let normalized = FloatingRecordButtonGeometry.normalized(point, in: bounds, previous: normalizedPosition)
        normalizedX = normalized.x
        normalizedY = normalized.y
    }

    private func move(x: Double, y: Double) {
        normalizedX = FloatingRecordButtonGeometry.fraction(FloatingRecordButtonGeometry.fraction(normalizedX) + x)
        normalizedY = FloatingRecordButtonGeometry.fraction(FloatingRecordButtonGeometry.fraction(normalizedY) + y)
    }
}

enum FloatingRecordButtonGeometry {
    static func bounds(size: CGSize, insets: EdgeInsets) -> CGRect {
        let radius = FloatingRecordButtonMetrics.diameter / 2
        let minX = min(size.width / 2, insets.leading + radius + 16)
        let maxX = max(minX, size.width - insets.trailing - radius - 16)
        let minY = min(size.height / 2, insets.top + radius + 16)
        let maxY = max(minY, size.height - insets.bottom - radius - FloatingRecordButtonMetrics.bottomPadding)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func fraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }

    static func point(normalized: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.minX + bounds.width * fraction(normalized.x),
            y: bounds.minY + bounds.height * fraction(normalized.y)
        )
    }

    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
    }

    static func normalized(_ point: CGPoint, in bounds: CGRect, previous: CGPoint) -> CGPoint {
        let point = clamped(point, to: bounds)
        return CGPoint(
            x: bounds.width > 0 ? (point.x - bounds.minX) / bounds.width : fraction(previous.x),
            y: bounds.height > 0 ? (point.y - bounds.minY) / bounds.height : fraction(previous.y)
        )
    }
}
