import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes grid thumbnails with ImageIO, from the preview the camera embeds in the file.
/// Only reads the photo; encoding and decoding the cached JPEG never touch the source either.
enum ThumbnailGenerator {
    /// Long side in pixels: a ~240 pt grid cell on a Retina screen, with a little margin.
    static let maxPixelSize = 512
    static let jpegQuality = 0.8

    /// Upright thumbnail (EXIF orientation applied), long side ≤ `maxPixelSize`, never enlarged.
    static func makeThumbnail(from url: URL, maxPixelSize: Int = maxPixelSize) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw AnalysisError.unreadableImage(url.lastPathComponent)
        }

        // 1. Embedded preview (1616×1080 on a Sony A6000), scaled down by ImageIO: no RAW decoding.
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies the EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let expectedLongSide = min(maxPixelSize, longSide(of: source) ?? maxPixelSize)
        if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           max(preview.width, preview.height) >= expectedLongSide {
            return preview
        }

        // 2. No preview, or a tiny one (the 160 px EXIF thumbnail of a JPEG): decode the image itself.
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AnalysisError.unreadableImage(url.lastPathComponent)
        }
        return decoded
    }

    static func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AnalysisError.imageProcessingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AnalysisError.imageProcessingFailed
        }
        return data as Data
    }

    /// Decodes a cached thumbnail right away, so the grid never decodes on the main thread while scrolling.
    static func decodeJPEG(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Long side of the full image, as the file declares it.
    private static func longSide(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(width, height)
    }
}
