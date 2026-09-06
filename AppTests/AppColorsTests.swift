import SwiftUI
import XCTest
@testable import Transcript

@MainActor
final class AppColorsTests: XCTestCase {
    func testControlTintMeetsTextContrastInLightDarkAndIncreasedContrast() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style),
                    UITraitCollection(accessibilityContrast: contrast)
                ])
                let tint = UIColor(AppColors.controlTint).resolvedColor(with: traits)
                let backgrounds: [UIColor] = [
                    .systemBackground, .secondarySystemGroupedBackground, .tertiarySystemGroupedBackground,
                    style == .dark ? UIColor(white: 0.23, alpha: 1) : .white
                ]
                for background in backgrounds {
                    XCTAssertGreaterThanOrEqual(
                        contrastRatio(tint, background.resolvedColor(with: traits)),
                        contrast == .high ? 7 : 4.5,
                        "\(style) / \(contrast) / \(background)"
                    )
                }
            }
        }
    }

    func testSettingsBackgroundSupportsLabelsInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            XCTAssertGreaterThanOrEqual(contrastRatio(
                UIColor.label.resolvedColor(with: traits),
                UIColor(AppColors.settingsBackground).resolvedColor(with: traits)
            ), 7)
        }
    }

    func testDeepBlueRecordingFillKeepsWhiteSymbolContrast() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let fill = UIColor(FloatingRecordButton.accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            XCTAssertGreaterThanOrEqual(contrastRatio(.white, fill), 7)
        }
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            func linear(_ channel: CGFloat) -> Double {
                let value = Double(channel)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
