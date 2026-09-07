import XCTest
import SwiftUI
@testable import Transcript

@MainActor
final class ForegroundIdleTimerTests: XCTestCase {
    func testForegroundKeepsScreenAwakeWithoutARecordingSession() {
        var writes: [Bool] = []
        let timer = ForegroundIdleTimer { writes.append($0) }
        let root = UUID()
        timer.update(owner: root, isActive: true)
        timer.update(owner: root, isActive: true)
        XCTAssertEqual(writes, [true])
    }

    func testInactiveBackgroundAndDisappearanceReleaseIdempotently() {
        var writes: [Bool] = []
        let timer = ForegroundIdleTimer { writes.append($0) }
        let root = UUID()
        timer.update(owner: root, isActive: true)
        timer.update(owner: root, isActive: false) // inactive
        timer.update(owner: root, isActive: false) // background
        timer.update(owner: root, isActive: true)
        timer.update(owner: root, isActive: false) // disappearance
        XCTAssertEqual(writes, [true, false, true, false])
    }

    func testOneSceneCannotReleaseAnotherActiveScene() {
        var writes: [Bool] = []
        let timer = ForegroundIdleTimer { writes.append($0) }
        let first = UUID()
        let second = UUID()
        timer.update(owner: first, isActive: true)
        timer.update(owner: second, isActive: true)
        timer.update(owner: first, isActive: false)
        timer.update(owner: UUID(), isActive: false)
        XCTAssertEqual(writes, [true])
        timer.update(owner: second, isActive: false)
        XCTAssertEqual(writes, [true, false])
    }

    func testVisibleRootLifecycleReleasesOnInactiveAndRemoval() async throws {
        var writes: [Bool] = []
        let timer = ForegroundIdleTimer { writes.append($0) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        func root(_ phase: ScenePhase) -> some View {
            Color.clear
                .modifier(ForegroundIdleTimerLifecycle(timer: timer))
                .environment(\.scenePhase, phase)
        }
        let controller = UIHostingController(rootView: root(.active))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes, [true])
        controller.rootView = root(.inactive)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes, [true, false])
        controller.rootView = root(.background)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes, [true, false])
        controller.rootView = root(.active)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes, [true, false, true])
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes, [true, false, true, false])
    }
}
