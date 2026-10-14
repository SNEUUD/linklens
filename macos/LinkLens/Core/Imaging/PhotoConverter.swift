import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a converted photo looks like. Set by the presets (`ExportPreset`), never shown to the user.
struct PhotoOutputSettings: Sendable, Equatable {
    enum Format: Sendable, Equatable {
        case jpeg, heic, tiff

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            case .tiff: "tif"
            }
        }

        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            }
        }

        var isLossy: Bool { self != .tiff }
    }

    enum ColorSpace: Sendable, Equatable {
        /// The web and most printing labs.
        case sRGB
        /// Wider colours, shown correctly by Apple devices.
        case displayP3

        var cgColorSpace: CGColorSpace {
            // Both are built into the system: these initializers never return nil.
            switch self {
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
            }
        }
    }

    var format: Format
    /// Long side in pixels; nil keeps the full resolution. A smaller photo is never enlarged.
    var maxLongSide: Int?
    /// 0…1, used by JPEG and HEIC only.
    var quality: Double
    var colorSpace: ColorSpace
    /// Written in the file for printing (e.g. 300); nil keeps the default 72.
    var dotsPerInch: Int?
    /// GPS position of the shot. Removed from photos meant to be posted online.
    var keepsLocation: Bool
}

/// Errors of one converted file. They never stop a whole export: the photo is listed as failed.
enum ConversionError: LocalizedError, Equatable {
    case unreadableImage(String)
    case renderFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let name):
            String(localized: "Impossible de lire l'image « \(name) ».")
        case .renderFailed(let name):
            String(localized: "Impossible de convertir l'image « \(name) ».")
        case .writeFailed(let name):
            String(localized: "Impossible d'enregistrer le fichier « \(name) ».")
        }
    }
}

/// Converts one photo file into a new file, at full quality. The source file is only read.
///
/// A RAW is developed from its sensor data with Core Image (`CIRAWFilter`), not from the small
/// JPEG preview the camera embeds (that one is only good enough for sorting).
enum PhotoConverter {
    /// Pixel size of the written image, in display orientation.
    struct Result: Sendable, Equatable {
        var width: Int
        var height: Int
    }

    /// Writes `source` converted to `destination`. `destination` must not exist yet (see `PhotoExporter`).
    ///
    /// `CIContext` is thread-safe and costly to create: one is shared by every photo of an export.
    @discardableResult
    static func convert(
        _ source: URL,
        to destination: URL,
        settings: PhotoOutputSettings,
        context: CIContext
    ) throws -> Result {
        let name = source.lastPathComponent
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, sourceOptions),
              CGImageSourceGetCount(imageSource) > 0
        else {
            throw ConversionError.unreadableImage(name)
        }
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, sourceOptions) as? [CFString: Any] ?? [:]

        let image = try loadUprightImage(source, imageSource: imageSource)
        let size = targetSize(
            width: Int(image.extent.width.rounded()),
            height: Int(image.extent.height.rounded()),
            maxLongSide: settings.maxLongSide
        )
        let scaled = resize(image, width: size.width, height: size.height)
        let cgImage = try render(scaled, width: size.width, height: size.height, settings: settings, context: context, name: name)

        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL, settings.format.type.identifier as CFString, 1, nil
        ) else {
            throw ConversionError.writeFailed(destination.lastPathComponent)
        }
        CGImageDestinationAddImage(output, cgImage, outputProperties(from: sourceProperties, settings: settings) as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw ConversionError.writeFailed(destination.lastPathComponent)
        }
        return Result(width: size.width, height: size.height)
    }

    /// Full-size image with the EXIF orientation applied (a portrait comes out as a portrait).
    static func loadUprightImage(_ url: URL, imageSource: CGImageSource) throws -> CIImage {
        let name = url.lastPathComponent
        let type = (CGImageSourceGetType(imageSource) as String?).flatMap(UTType.init)
        let image: CIImage?
        if type?.conforms(to: .rawImage) == true {
            // `CIRAWFilter` develops the sensor data like the camera would (white balance, exposure,
            // noise reduction, lens corrections when known). It applies the orientation by default.
            image = CIRAWFilter(imageURL: url)?.outputImage
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let image, !image.extent.isInfinite, !image.extent.isEmpty else {
            throw ConversionError.unreadableImage(name)
        }
        // Moves the image to (0, 0): the following steps work in pixel coordinates.
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Size after applying `maxLongSide`, keeping the proportions. Never enlarges.
    static func targetSize(width: Int, height: Int, maxLongSide: Int?) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard let maxLongSide, longSide > maxLongSide, longSide > 0 else {
            return (width, height)
        }
        let scale = Double(maxLongSide) / Double(longSide)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// High-quality reduction (Lanczos) to exactly `width` × `height`.
    private static func resize(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let scaleX = CGFloat(width) / image.extent.width
        let scaleY = CGFloat(height) / image.extent.height
        guard abs(scaleX - 1) > 0.0001 || abs(scaleY - 1) > 0.0001 else { return image }
        // Extending the edges first avoids a dark border, then the result is cut back to size.
        return image.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Renders into an opaque 8-bit bitmap (no alpha channel: smaller HEIC and TIFF files).
    ///
    /// 8 bits only: a 16-bit TIFF of a 24 Mpx photo weighs 144 MB, against 24 MB for an 8-bit TIFF
    /// compressed without loss (measured on the A6000 RAW files).
    private static func render(
        _ image: CIImage,
        width: Int,
        height: Int,
        settings: PhotoOutputSettings,
        context: CIContext,
        name: String
    ) throws -> CGImage {
        let colorSpace = settings.colorSpace.cgColorSpace
        guard let bitmap = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let data = bitmap.data else {
            throw ConversionError.renderFailed(name)
        }
        context.render(
            image,
            toBitmap: data,
            rowBytes: bitmap.bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )
        guard let cgImage = bitmap.makeImage() else {
            throw ConversionError.renderFailed(name)
        }
        return cgImage
    }

    /// Metadata written in the new file: date, camera, lens and shooting settings are kept.
    /// The pixels are already upright, so the orientation becomes 1 ("normal").
    static func outputProperties(from source: [CFString: Any], settings: PhotoOutputSettings) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1]

        if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // Describe the original size: the new file has its own.
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if let sourceTIFF = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            // Only the descriptive fields: the RAW's own layout fields (compression, strips…) do not apply.
            let keptKeys = [
                kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription,
            ]
            for key in keptKeys {
                tiff[key] = sourceTIFF[key]
            }
        }
        if settings.format == .tiff {
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW: lossless, about 3 times smaller
        }
        properties[kCGImagePropertyTIFFDictionary] = tiff
        for key in [kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary] {
            properties[key] = source[key]
        }
        if settings.keepsLocation {
            properties[kCGImagePropertyGPSDictionary] = source[kCGImagePropertyGPSDictionary]
        }
        if let dotsPerInch = settings.dotsPerInch {
            properties[kCGImagePropertyDPIWidth] = dotsPerInch
            properties[kCGImagePropertyDPIHeight] = dotsPerInch
        }
        if settings.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        return properties
    }
}
