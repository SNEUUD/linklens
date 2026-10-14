import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes JPEG thumbnails for the contact sheet (browsers cannot display .ARW files).
/// Only ever writes inside the output folder.
public enum ThumbnailWriter {
    public static let longSide = 800

    /// File name inside `thumbs/` for a photo ("sub/DSC1.ARW" → "sub__DSC1.jpg").
    public static func fileName(for relativePath: String) -> String {
        let base = (relativePath as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "__")
        return base + ".jpg"
    }

    public static func write(_ image: CGImage, to url: URL) throws {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ProbeError.imageProcessingFailed("miniature") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ProbeError.imageProcessingFailed("miniature") }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProbeError.imageProcessingFailed("écriture de la miniature") }
    }
}
