import Foundation
import ImageIO

struct PhotoMetadata: Sendable, Equatable {
    var captureDate: Date?
    /// Dimensions as displayed (width and height swapped for portrait photos), 0 when unknown.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Camera, lens and settings (EXIF), shown by the inspector. Empty for a video or a file without EXIF.
    var capture = CaptureInfo()
    /// Length of a video, in seconds. Nil for a photo, or a video AVFoundation cannot open.
    var duration: Double? = nil

    static let unknown = PhotoMetadata(captureDate: nil, pixelWidth: 0, pixelHeight: 0)
}

/// What the camera wrote about how the photo was taken. Every field is optional: phones, scanners
/// and edited files often leave some out.
struct CaptureInfo: Sendable, Equatable {
    /// « SONY », « Canon », « Apple ».
    var cameraMake: String?
    /// « ILCE-6000 », « Canon EOS R6 », « iPhone 15 Pro ».
    var cameraModel: String?
    /// « E 55-210mm F4.5-6.3 OSS ».
    var lensModel: String?
    /// Shutter speed, in seconds (0.00625 = 1/160 s).
    var exposureTime: Double?
    /// Aperture: 5.6 for f/5,6.
    var fNumber: Double?
    var iso: Int?
    /// Focal length, in millimetres (as written by the camera, not the 35 mm equivalent).
    var focalLength: Double?
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
        return PhotoMetadata(captureDate: date, pixelWidth: width, pixelHeight: height, capture: captureInfo(from: properties))
    }

    /// Camera, lens and settings from the ImageIO properties of a file (TIFF, EXIF and EXIF aux dictionaries).
    static func captureInfo(from properties: [CFString: Any]) -> CaptureInfo {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        // `as? NSNumber` then `.doubleValue`: EXIF numbers come as Objective-C numbers.
        func number(_ dictionary: [CFString: Any], _ key: CFString) -> Double? {
            (dictionary[key] as? NSNumber)?.doubleValue
        }
        func text(_ dictionary: [CFString: Any], _ key: CFString) -> String? {
            // Some cameras pad their strings with spaces or NUL characters.
            let value = (dictionary[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            return value?.isEmpty == false ? value : nil
        }
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        return CaptureInfo(
            cameraMake: text(tiff, kCGImagePropertyTIFFMake),
            cameraModel: text(tiff, kCGImagePropertyTIFFModel),
            lensModel: text(exif, kCGImagePropertyExifLensModel) ?? text(exifAux, kCGImagePropertyExifAuxLensModel),
            exposureTime: number(exif, kCGImagePropertyExifExposureTime).flatMap { $0 > 0 ? $0 : nil },
            fNumber: number(exif, kCGImagePropertyExifFNumber).flatMap { $0 > 0 ? $0 : nil },
            iso: iso.flatMap { $0 > 0 ? $0 : nil },
            focalLength: number(exif, kCGImagePropertyExifFocalLength).flatMap { $0 > 0 ? $0 : nil }
        )
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
