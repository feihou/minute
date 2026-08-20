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

/// Square brand-gradient tile with a white waveform glyph. Decorative only,
/// so it is always hidden from accessibility.
struct BrandIconTile: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient.brand)
            Image(systemName: "waveform")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Reading surfaces

/// Spacing scale for the screens that present content as a document —
/// meeting notes, transcripts, entity pages. Rhythm comes from these few
/// steps rather than a bespoke number at every call site.
enum Layout {
    /// Side margin for body text on a reading surface.
    static let margin: CGFloat = 20
    /// Space above a section heading — the main separator between blocks,
    /// standing in for the card edges and rules a form would use.
    static let sectionGap: CGFloat = 30
    /// Heading to its first line of content.
    static let headingGap: CGFloat = 10
    /// Between sibling items inside one section.
    static let itemGap: CGFloat = 12
}

/// Section label for reading surfaces: small, uppercase, wide-tracked, and
/// sitting in the flow of the page. Deliberately unadorned — an icon per
/// heading reads as decoration once there are six of them down one screen.
struct SectionHeading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.9)
            .foregroundStyle(.secondary)
            // Uppercasing is a visual treatment. Without this the transformed
            // string becomes the name VoiceOver reads, a braille display shows,
            // and a UI test queries — "WHAT YOU KNOW" rather than the title.
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Bullet with the dot in its own gutter, so wrapped lines align under the
/// text instead of under the dot.
struct BulletRow<Content: View>: View {
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(tint.opacity(0.6))
                .frame(width: 5, height: 5)
                // Drops the dot to the middle of the first line's cap height.
                .padding(.top, 7)
                .accessibilityHidden(true)
            content
        }
    }
}

extension BulletRow where Content == Text {
    init(_ text: String, tint: Color = .accentColor) {
        self.init(tint: tint) { Text(text) }
    }
}
