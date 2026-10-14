import Foundation

/// F6: the four one-click export formats. The technical values stay hidden: only the title and a
/// sentence about what the file is for are shown.
///
/// `CaseIterable` gives `ExportPreset.allCases` (like `Object.values` on a TypeScript enum object),
/// used to draw one card per preset.
enum ExportPreset: String, CaseIterable, Identifiable, Sendable {
    case webJPEG
    case printJPEG
    case heic
    case tiff

    var id: Self { self }

    var settings: PhotoOutputSettings {
        switch self {
        case .webJPEG:
            // Sharp on any screen, about 0.4 MB. Without the GPS position: these photos go online.
            PhotoOutputSettings(format: .jpeg, maxLongSide: 2048, quality: 0.8, colorSpace: .sRGB, dotsPerInch: nil, keepsLocation: false)
        case .printJPEG:
            // Full resolution (6000 × 4000 on the A6000), about 5 MB, sRGB as printing labs expect.
            PhotoOutputSettings(format: .jpeg, maxLongSide: nil, quality: 0.92, colorSpace: .sRGB, dotsPerInch: 300, keepsLocation: true)
        case .heic:
            // Full resolution, about 1.7 MB, wider colours for Apple devices.
            PhotoOutputSettings(format: .heic, maxLongSide: nil, quality: 0.85, colorSpace: .displayP3, dotsPerInch: nil, keepsLocation: true)
        case .tiff:
            // Lossless, about 24 MB: for retouching or a demanding printer.
            PhotoOutputSettings(format: .tiff, maxLongSide: nil, quality: 1, colorSpace: .sRGB, dotsPerInch: 300, keepsLocation: true)
        }
    }

    // `LocalizedStringResource` is a text looked up in `Localizable.xcstrings` when displayed,
    // like a translation key passed to `t()` in i18next.
    var title: LocalizedStringResource {
        switch self {
        case .webJPEG: "JPEG pour le web"
        case .printJPEG: "JPEG pour l'impression"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        }
    }

    var purpose: LocalizedStringResource {
        switch self {
        case .webJPEG: "Pour envoyer par e-mail ou publier en ligne. Fichiers légers."
        case .printJPEG: "Pour faire tirer vos photos. Pleine résolution."
        case .heic: "Pour les appareils Apple. Pleine résolution, deux fois plus léger qu'un JPEG."
        case .tiff: "Sans aucune perte, pour la retouche. Fichiers très lourds."
        }
    }

    /// Shown only as a tooltip, for the curious.
    var details: LocalizedStringResource {
        switch self {
        case .webJPEG: "2048 pixels de côté, sRGB, qualité 80 %, sans position GPS"
        case .printJPEG: "Pleine résolution, sRGB, qualité 92 %, 300 ppp"
        case .heic: "Pleine résolution, Display P3, qualité 85 %"
        case .tiff: "Pleine résolution, 8 bits, sRGB, compression sans perte (LZW), 300 ppp"
        }
    }

    var systemImage: String {
        switch self {
        case .webJPEG: "globe"
        case .printJPEG: "printer"
        case .heic: "iphone"
        case .tiff: "wand.and.rays"
        }
    }
}
