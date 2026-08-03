import SwiftUI

/// Shared brand styling. The palette derives from the app's AccentColor so
/// light/dark variants stay in sync with the asset catalog.
extension LinearGradient {
    /// Primary brand fill for icon tiles, hero buttons, and headers.
    /// Shades toward black instead of fading alpha so white text keeps
    /// WCAG-level contrast over light backgrounds.
    static let brand = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.mix(with: .black, by: 0.18)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Dark immersive backdrop for the recording screen.
    static let studioBackdrop = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.11, blue: 0.22),
            Color(red: 0.04, green: 0.04, blue: 0.09),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
