import CoreGraphics
import Foundation
import ImageIO

/// Errors of the per-photo analysis. They never stop a whole gallery: the photo gets "À revoir".
enum AnalysisError: LocalizedError, Equatable {
    case unreadableImage(String)
    case imageProcessingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let name):
            String(localized: "Impossible de lire l'image « \(name) ».")
        case .imageProcessingFailed:
            String(localized: "Impossible de préparer l'image pour l'analyse.")
        }
    }
}

/// Reads an analysis-sized image with ImageIO, without ever modifying the file.
enum PreviewLoader {
    /// Below this size the embedded preview is considered too small (typical JPEG thumbnails are 160 px).
    static let minimumPreviewSize = 1000
    static let maxPixelSize = 2048

    /// Upright image (EXIF orientation already applied), long side ≤ `maxPixelSize`.
    static func load(url: URL) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw AnalysisError.unreadableImage(url.lastPathComponent)
        }

        // 1. JPEG preview embedded by the camera in the RAW: no RAW decoding, ~20 ms per file.
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies the EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           max(preview.width, preview.height) >= minimumPreviewSize {
            return preview
        }

        // 2. Fallback: decode the real image at a reduced size (JPEG/HEIC, or RAW without preview).
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AnalysisError.unreadableImage(url.lastPathComponent)
        }
        return decoded
    }
}
