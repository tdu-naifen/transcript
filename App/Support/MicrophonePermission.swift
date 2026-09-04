import AVFoundation
import Foundation
import UIKit

enum MicrophonePermission {
    enum Status: Sendable, Equatable {
        case undetermined
        case granted
        case denied
    }

    static var current: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    static func request() async -> Status {
        if current == .granted { return .granted }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        return granted ? .granted : .denied
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
