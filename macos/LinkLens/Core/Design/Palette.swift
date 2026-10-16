import AppKit
import SwiftUI

/// An sRGB colour written like in CSS (`HexColor(hex: 0x1A7334)` is `#1a7334`), with the WCAG
/// contrast maths used to check that text stays readable.
struct HexColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// WCAG 2 relative luminance: 0 for black, 1 for white.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, from 1 (same colour) to 21 (black on white). Text needs 4.5.
    func contrastRatio(with other: HexColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// A colour with one value for light mode and one for dark mode, like a CSS variable redefined
/// under `@media (prefers-color-scheme: dark)`. macOS picks the value while drawing, so the view
/// follows the system appearance without being redrawn by hand.
struct AdaptiveColor: Sendable {
    let light: HexColor
    let dark: HexColor
    /// 1 for an opaque colour; below 1, the colour lets what is behind show through (like `rgba(…)`).
    let lightOpacity: Double
    let darkOpacity: Double

    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.light = HexColor(hex: light)
        self.dark = HexColor(hex: dark)
        self.lightOpacity = lightOpacity
        self.darkOpacity = darkOpacity
    }

    /// An AppKit colour that resolves to `light` or `dark` while drawing.
    var nsColor: NSColor {
        let light = light.nsColor.withAlphaComponent(lightOpacity)
        let dark = dark.nsColor.withAlphaComponent(darkOpacity)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    var color: Color {
        Color(nsColor: nsColor)
    }
}

/// The colours of the app, from the approved mockup. Light values are a little darker than the
/// mockup's so that text reaches a 4.5:1 contrast on every light surface (checked by `DesignTests`).
enum Palette {
    static let keep = AdaptiveColor(light: 0x1A7334, dark: 0x45D97A)
    static let review = AdaptiveColor(light: 0x9A4D00, dark: 0xFFAE42)
    static let reject = AdaptiveColor(light: 0xC4001A, dark: 0xFF6B6B)
    /// Same values as the `AccentColor` asset, which is the app's accent (buttons, selection).
    /// The user's own accent colour in System Settings still wins, as in every Mac app.
    static let accent = AdaptiveColor(light: 0x005FC4, dark: 0x4AA3FF)
    /// Star of the best photo of a burst: an icon, so 3:1 is enough.
    static let gold = AdaptiveColor(light: 0x8F5D00, dark: 0xFFCC4D)

    /// Selected segment of a capsule (the filters): a raised chip, as in the mockup.
    static let chip = AdaptiveColor(light: 0xFFFFFF, dark: 0x45454C)
    /// Behind the badges drawn over a photo (verdict, star, burst count). Nearly opaque, like the
    /// mockup's: a real blur on every badge of a grid of hundreds of photos would slow the scrolling.
    static let badge = AdaptiveColor(light: 0xFFFFFF, dark: 0x1E1E22, lightOpacity: 0.88, darkOpacity: 0.82)
    /// The two prints peeking out behind a collapsed burst: front one, then back one.
    static let stackFront = AdaptiveColor(light: 0xCFD0D6, dark: 0x3A3A40)
    static let stackBack = AdaptiveColor(light: 0xDCDDE2, dark: 0x2C2C31)
    /// Bands around a photo shown whole in a cell of another shape.
    static let photoBackground = AdaptiveColor(light: 0xDCDCE2, dark: 0x0C0C0E)

    /// The lightest and darkest backgrounds text is drawn on (window, sidebar, selected chip),
    /// in each mode. The contrast test checks every text colour against all of them.
    static let lightSurfaces = [0xFFFFFF, 0xF8F8FA, 0xECECF0, 0xE3E3E8].map(HexColor.init(hex:))
    static let darkSurfaces = [0x141416, 0x1E1E1E, 0x26262A, 0x323236].map(HexColor.init(hex:))
}

extension CullingVerdict {
    /// Verdict colour of the new interface, readable as text in light and dark mode.
    var tint: Color {
        switch self {
        case .keep: Palette.keep.color
        case .review: Palette.review.color
        case .reject: Palette.reject.color
        case .unknown: .secondary
        }
    }
}
