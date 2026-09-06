import SwiftUI

@MainActor
enum AppColors {
    static let controlTint = Color(uiColor: UIColor { traits in
        guard traits.userInterfaceStyle == .dark else {
            return UIColor(red: 6 / 255, green: 34 / 255, blue: 158 / 255, alpha: 1)
        }
        return traits.accessibilityContrast == .high
            ? UIColor(red: 195 / 255, green: 212 / 255, blue: 1, alpha: 1)
            : UIColor(red: 144 / 255, green: 174 / 255, blue: 1, alpha: 1)
    })
    // Filled controls retain the brand blue so their white symbols remain legible.
    static let filledControl = FloatingRecordButton.accent
    static let settingsBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGroupedBackground.resolvedColor(with: traits)
            : UIColor(red: 0.975, green: 0.97, blue: 0.96, alpha: 1)
    })
}
