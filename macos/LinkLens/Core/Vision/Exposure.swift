import Accelerate
import Foundation

struct ExposureMeasurement: Sendable, Equatable {
    /// Share of pixels ≥ `Exposure.highlightLevel` (0…1): burnt highlights.
    var highlightClipping: Double
    /// Share of pixels ≤ `Exposure.shadowLevel` (0…1): blocked shadows.
    var shadowClipping: Double
}

enum Exposure {
    static let highlightLevel = 250
    static let shadowLevel = 5

    static func measure(_ gray: GrayImage) -> ExposureMeasurement {
        var histogram = [vImagePixelCount](repeating: 0, count: 256)
        var pixels = gray.pixels
        pixels.withUnsafeMutableBytes { bytes in
            var buffer = vImage_Buffer(
                data: bytes.baseAddress, height: vImagePixelCount(gray.height),
                width: vImagePixelCount(gray.width), rowBytes: gray.width
            )
            _ = vImageHistogramCalculation_Planar8(&buffer, &histogram, vImage_Flags(kvImageNoFlags))
        }
        let total = Double(max(1, gray.width * gray.height))
        let bright = histogram[highlightLevel...].reduce(0, +)
        let dark = histogram[...shadowLevel].reduce(0, +)
        return ExposureMeasurement(highlightClipping: Double(bright) / total, shadowClipping: Double(dark) / total)
    }
}
