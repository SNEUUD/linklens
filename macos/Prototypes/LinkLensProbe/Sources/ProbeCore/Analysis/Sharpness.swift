import Accelerate
import Foundation

public struct SharpnessMeasurement: Sendable, Equatable {
    /// Mean Laplacian variance of the 2 sharpest tiles out of a 4×4 grid (used for the verdict).
    /// Tiles avoid calling a photo "blurry" just because its background is out of focus.
    public var sharpness: Double
    /// Laplacian variance over the whole image (kept in the report for comparison).
    public var globalSharpness: Double
}

/// Blur detection: variance of the Laplacian.
/// The Laplacian highlights edges; a sharp image has strong, varied edges (high variance),
/// a blurry image has soft edges (low variance).
public enum Sharpness {
    static let gridSize = 4
    static let sharpestTileCount = 2

    public static func measure(_ gray: GrayImage) -> SharpnessMeasurement {
        let width = gray.width, height = gray.height
        guard width >= 3, height >= 3 else { return SharpnessMeasurement(sharpness: 0, globalSharpness: 0) }

        // UInt8 → Float, then 3×3 Laplacian convolution with vImage (Accelerate).
        var source = vDSP.integerToFloatingPoint(gray.pixels, floatingPointType: Float.self)
        var laplacian = [Float](repeating: 0, count: width * height)
        let kernel: [Float] = [0, 1, 0,
                               1, -4, 1,
                               0, 1, 0]
        source.withUnsafeMutableBytes { sourceBytes in
            laplacian.withUnsafeMutableBytes { destinationBytes in
                var sourceBuffer = vImage_Buffer(
                    data: sourceBytes.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size
                )
                var destinationBuffer = vImage_Buffer(
                    data: destinationBytes.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size
                )
                _ = vImageConvolve_PlanarF(
                    &sourceBuffer, &destinationBuffer, nil, 0, 0,
                    kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend)
                )
            }
        }

        // Sum and sum of squares per tile (variance = E[x²] − E[x]²).
        let grid = gridSize
        var sums = [Double](repeating: 0, count: grid * grid)
        var squares = [Double](repeating: 0, count: grid * grid)
        var counts = [Int](repeating: 0, count: grid * grid)
        for y in 1..<(height - 1) { // skip the 1-pixel border affected by edge extension
            let tileRow = min(grid - 1, y * grid / height)
            let rowStart = y * width
            for x in 1..<(width - 1) {
                let tile = tileRow * grid + min(grid - 1, x * grid / width)
                let value = Double(laplacian[rowStart + x])
                sums[tile] += value
                squares[tile] += value * value
                counts[tile] += 1
            }
        }

        func variance(sum: Double, square: Double, count: Int) -> Double {
            guard count > 0 else { return 0 }
            let mean = sum / Double(count)
            return max(0, square / Double(count) - mean * mean)
        }
        let tileVariances = (0..<(grid * grid)).map { variance(sum: sums[$0], square: squares[$0], count: counts[$0]) }
        let sharpest = tileVariances.sorted(by: >).prefix(sharpestTileCount)
        let global = variance(sum: sums.reduce(0, +), square: squares.reduce(0, +), count: counts.reduce(0, +))
        return SharpnessMeasurement(sharpness: sharpest.reduce(0, +) / Double(sharpest.count), globalSharpness: global)
    }
}
