import AppKit
import Testing
@testable import LinkLens

/// Shared style of the new interface: readable colours in both modes, the accent, the glass fallback.
@MainActor
struct DesignTests {
    // MARK: - Contrast

    @Test func contrastMathsMatchesWCAG() {
        let black = HexColor(hex: 0x000000)
        let white = HexColor(hex: 0xFFFFFF)
        #expect(abs(black.contrastRatio(with: white) - 21) < 0.01)
        #expect(white.contrastRatio(with: white) == 1)
        // Reference value from the WCAG contrast checker: #767676 on white is 4.54:1.
        #expect(abs(HexColor(hex: 0x767676).contrastRatio(with: white) - 4.54) < 0.01)
    }

    @Test(arguments: [
        ("Garder", Palette.keep),
        ("À revoir", Palette.review),
        ("Rejeter", Palette.reject),
        ("Accent", Palette.accent),
    ])
    func textColoursAreReadableInLightAndDarkMode(name: String, color: AdaptiveColor) {
        for surface in Palette.lightSurfaces {
            #expect(color.light.contrastRatio(with: surface) >= 4.5, "\(name), light mode, on \(surface)")
        }
        for surface in Palette.darkSurfaces {
            #expect(color.dark.contrastRatio(with: surface) >= 4.5, "\(name), dark mode, on \(surface)")
        }
    }

    @Test func theStarIsVisibleInBothModes() {
        // An icon, not text: WCAG asks 3:1 for graphics.
        for surface in Palette.lightSurfaces { #expect(Palette.gold.light.contrastRatio(with: surface) >= 3) }
        for surface in Palette.darkSurfaces { #expect(Palette.gold.dark.contrastRatio(with: surface) >= 3) }
    }

    @Test func whiteTextOnTheAccentIsReadable() {
        // « Importer… » on the detected card: white on the accent colour.
        #expect(HexColor(hex: 0xFFFFFF).contrastRatio(with: Palette.accent.light) >= 4.5)
    }

    @Test func adaptiveColoursFollowTheAppearance() throws {
        let color = Palette.keep.nsColor
        #expect(try resolved(color, in: .aqua) == Palette.keep.light)
        #expect(try resolved(color, in: .darkAqua) == Palette.keep.dark)
    }

    @Test func theAccentAssetMatchesThePalette() throws {
        let asset = try #require(NSColor(named: "AccentColor"), "AccentColor in Assets.xcassets")
        #expect(try resolved(asset, in: .aqua) == Palette.accent.light)
        #expect(try resolved(asset, in: .darkAqua) == Palette.accent.dark)
    }

    // MARK: - Glass

    @Test func glassFallsBackToAMaterialBeforeMacOS26() {
        #expect(GlassStyle.resolve(supportsLiquidGlass: true, reduceTransparency: false) == .liquidGlass)
        #expect(GlassStyle.resolve(supportsLiquidGlass: false, reduceTransparency: false) == .material)
    }

    @Test func reduceTransparencyGivesAnOpaqueBackground() {
        #expect(GlassStyle.resolve(supportsLiquidGlass: true, reduceTransparency: true) == .opaque)
        #expect(GlassStyle.resolve(supportsLiquidGlass: false, reduceTransparency: true) == .opaque)
    }

    @Test func liquidGlassIsUsedFromMacOS26() {
        let isMacOS26OrLater = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        #expect(GlassStyle.systemSupportsLiquidGlass == isMacOS26OrLater)
    }

    // MARK: - Helpers

    /// The sRGB value an appearance-dependent colour takes while drawing in `appearance`.
    private func resolved(_ color: NSColor, in appearance: NSAppearance.Name) throws -> HexColor {
        var result: NSColor?
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        let srgb = try #require(result)
        let hex = (UInt32((srgb.redComponent * 255).rounded()) << 16)
            | (UInt32((srgb.greenComponent * 255).rounded()) << 8)
            | UInt32((srgb.blueComponent * 255).rounded())
        return HexColor(hex: hex)
    }
}
