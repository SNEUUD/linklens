import CoreGraphics
import Foundation
import ImageIO

/// Where the analysed pixels come from.
public enum PreviewSource: String, Codable, Sendable {
    /// JPEG preview embedded in the file by the camera (fast).
    case embedded
    /// Full image decoded by ImageIO then downscaled (slow fallback, e.g. JPEG/HEIC or RAW without preview).
    case decoded
}

public struct PhotoMetadata: Sendable, Equatable {
    public var captureDate: Date?
    /// Dimensions as displayed (width and height swapped for portrait photos).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var orientation: UInt32
}

public struct LoadedPreview {
    /// Upright image (EXIF orientation already applied), long side ≤ `PreviewLoader.maxPixelSize`.
    public let image: CGImage
    public let metadata: PhotoMetadata
    public let source: PreviewSource
}

/// Reads metadata and an analysis-sized image with ImageIO, without ever modifying the file.
public enum PreviewLoader {
    /// Below this size the embedded preview is considered too small (typical JPEG thumbnails are 160 px).
    static let minimumPreviewSize = 1000
    static let maxPixelSize = 2048

    public static func load(url: URL) throws -> LoadedPreview {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ProbeError.unreadableImage(url.lastPathComponent)
        }
        let metadata = readMetadata(source)

        // 1. Embedded preview: no RAW decoding, ~20 ms per file.
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies the EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           max(preview.width, preview.height) >= minimumPreviewSize {
            return LoadedPreview(image: preview, metadata: metadata, source: .embedded)
        }

        // 2. Fallback: decode the real image at a reduced size.
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProbeError.unreadableImage(url.lastPathComponent)
        }
        return LoadedPreview(image: decoded, metadata: metadata, source: .decoded)
    }

    static func readMetadata(_ source: CGImageSource) -> PhotoMetadata {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if (5...8).contains(orientation) { swap(&width, &height) }

        let date = parseExifDate(
            exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
        )
        return PhotoMetadata(captureDate: date, pixelWidth: width, pixelHeight: height, orientation: orientation)
    }

    /// Parses "2026:09:20 14:40:57" (camera local time, no time zone) plus optional sub-seconds ("25" = 0.25 s).
    static func parseExifDate(_ text: String?, subseconds: String?) -> Date? {
        guard let text else { return nil }
        let numbers = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard numbers.count == 6 else { return nil }
        let components = DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2],
            hour: numbers[3], minute: numbers[4], second: numbers[5]
        )
        guard let date = Calendar.current.date(from: components) else { return nil }
        if let subseconds, let fraction = Double("0." + subseconds.trimmingCharacters(in: .whitespaces)) {
            return date.addingTimeInterval(fraction)
        }
        return date
    }
}
