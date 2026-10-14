import Foundation
import ImageIO

struct PhotoMetadata: Sendable, Equatable {
    var captureDate: Date?
    /// Dimensions as displayed (width and height swapped for portrait photos), 0 when unknown.
    var pixelWidth: Int
    var pixelHeight: Int

    static let unknown = PhotoMetadata(captureDate: nil, pixelWidth: 0, pixelHeight: 0)
}

/// Reads EXIF metadata with ImageIO. Only the file header is read: no pixel is decoded.
enum PhotoMetadataReader {
    /// An unreadable file still gets indexed, with `PhotoMetadata.unknown`.
    static func read(url: URL) -> PhotoMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else {
            return .unknown
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if (5...8).contains(orientation) { swap(&width, &height) }

        let date = parseExifDate(
            exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
        )
        return PhotoMetadata(captureDate: date, pixelWidth: width, pixelHeight: height)
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
