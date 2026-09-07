import CoreGraphics
import Foundation

/// Distance is the commitment signal. Velocity affects only the release motion,
/// never whether a brief flick can enqueue a meeting.
enum SubmissionMotion {
    static func threshold(height: CGFloat) -> CGFloat {
        min(180, max(100, height.isFinite ? height * 0.22 : 100))
    }

    static func offset(translation: CGSize) -> CGFloat {
        guard translation.width.isFinite, translation.height.isFinite,
              -translation.height > abs(translation.width) else { return 0 }
        return min(0, translation.height)
    }

    static func isArmed(translation: CGSize, height: CGFloat) -> Bool {
        -offset(translation: translation) >= threshold(height: height)
    }

    static func settleDuration(distance: CGFloat, velocity: CGFloat) -> Double {
        let speed = velocity.isFinite ? min(2_000, abs(velocity)) : 0
        let travel = distance.isFinite ? abs(distance) : 0
        return Double(min(0.38, max(0.16, travel / max(700, speed))))
    }

    static func initialVelocity(distance: CGFloat, velocity: CGFloat) -> Double {
        guard distance.isFinite, velocity.isFinite, abs(distance) > 1 else { return 0 }
        return Double(min(6, max(-6, velocity / distance)))
    }
}

/// Consumed synchronously before any asynchronous recording/submission work.
struct UIActionGate {
    private(set) var isRunning = false

    mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func finish() { isRunning = false }
}

struct SubmissionDragState {
    private(set) var isTracking = false
    private(set) var isArmed = false

    /// Returns true only on entering the commit region, for boundary feedback.
    mutating func update(translation: CGSize, height: CGFloat) -> Bool {
        isTracking = true
        let armed = SubmissionMotion.isArmed(translation: translation, height: height)
        let entered = armed && !isArmed
        isArmed = armed
        return entered
    }

    mutating func end(translation: CGSize, height: CGFloat) -> Bool {
        let commits = isTracking && SubmissionMotion.isArmed(translation: translation, height: height)
        cancel()
        return commits
    }

    mutating func cancel() {
        isTracking = false
        isArmed = false
    }
}
