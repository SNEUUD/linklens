import CoreGraphics
import Foundation

/// 8-bit grayscale image, used for sharpness and exposure measurements.
/// A plain value type (struct): copying it is safe across tasks.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major pixels, 0 = black, 255 = white.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Draws `image` into a grayscale buffer whose long side is `longSide` pixels.
    public init(image: CGImage, longSide: Int) throws {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ProbeError.imageProcessingFailed("conversion en niveaux de gris") }
        self.init(width: width, height: height, pixels: pixels)
    }
}
