import SwiftUI
import UIKit

/// Each visible root owns a lease; one disappearing scene cannot release another.
@MainActor
final class ForegroundIdleTimer {
    static let shared = ForegroundIdleTimer { UIApplication.shared.isIdleTimerDisabled = $0 }

    private var activeOwners: Set<UUID> = []
    private let setDisabled: (Bool) -> Void

    init(setDisabled: @escaping (Bool) -> Void) {
        self.setDisabled = setDisabled
    }

    func update(owner: UUID, isActive: Bool) {
        let wasDisabled = !activeOwners.isEmpty
        if isActive { activeOwners.insert(owner) }
        else { activeOwners.remove(owner) }
        let isDisabled = !activeOwners.isEmpty
        if wasDisabled != isDisabled { setDisabled(isDisabled) }
    }
}

struct ForegroundIdleTimerLifecycle: ViewModifier {
    var timer: ForegroundIdleTimer = .shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = UUID()
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                timer.update(owner: owner, isActive: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                timer.update(owner: owner, isActive: isVisible && phase == .active)
            }
            .onDisappear {
                isVisible = false
                timer.update(owner: owner, isActive: false)
            }
    }
}
