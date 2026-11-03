import AVFoundation
import Foundation

/// F6: the two one-click formats for videos, shown next to the photo formats when the export
/// contains videos. As for photos, the technical values only appear in a tooltip.
///
/// Both write an `.mp4` file: the container every computer, phone and website reads. HEVC inside an
/// `.mp4` is tagged `hvc1` by AVFoundation, the tag QuickTime and iPhones need to play it.
enum VideoExportPreset: String, CaseIterable, Identifiable, Sendable {
    /// H.264, highest quality.
    case compatible
    /// HEVC (H.265), highest quality: about half the size of H.264, for devices from about 2017 on.
    case light

    var id: Self { self }

    /// The `AVAssetExportSession` preset. "Highest quality" keeps the original resolution and frame
    /// rate; an H.264 clip exported as H.264 is copied without being encoded again.
    var sessionPreset: String {
        switch self {
        case .compatible: AVAssetExportPresetHighestQuality
        case .light: AVAssetExportPresetHEVCHighestQuality
        }
    }

    var fileType: AVFileType { .mp4 }
    var fileExtension: String { "mp4" }

    var title: LocalizedStringResource {
        switch self {
        case .compatible: "Compatible partout"
        case .light: "Plus léger"
        }
    }

    var purpose: LocalizedStringResource {
        switch self {
        case .compatible: "Se lit sur tous les ordinateurs, téléphones et sites."
        case .light: "Environ deux fois plus léger, pour les appareils récents."
        }
    }

    /// Shown only as a tooltip, for the curious.
    var details: LocalizedStringResource {
        switch self {
        case .compatible: "MP4, H.264, qualité maximale. Avec « JPEG pour le web », sans position GPS."
        case .light: "MP4, HEVC (H.265), qualité maximale. Avec « JPEG pour le web », sans position GPS."
        }
    }

    var systemImage: String {
        switch self {
        case .compatible: "play.rectangle"
        case .light: "leaf"
        }
    }
}
