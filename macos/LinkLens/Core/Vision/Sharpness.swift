import Accelerate
import CoreGraphics
import Foundation

struct SharpnessMeasurement: Sendable, Equatable {
    /// Score used for the verdict: Laplacian variance divided by the intensity variance (× 1000),
    /// measured on the subject box (or the whole image when no subject was found).
    /// Dividing by the contrast keeps a sharp dark car from looking blurry.
    var sharpness: Double
    /// True if `sharpness` was measured on the subject, false if on the whole image.
    var measuredOnSubject: Bool
    /// Raw Laplacian variance of the 2 sharpest tiles out of 4×4 (prototype method, kept for comparison).
    var tileSharpness: Double
    /// Raw Laplacian variance over the whole image.
    var globalSharpness: Double
}

/// Blur detection: variance of the Laplacian.
/// The Laplacian highlights edges; a sharp image has strong, varied edges (high variance),
/// a blurry image has soft edges (low variance).
enum Sharpness {
    static let gridSize = 4
    static let sharpestTileCount = 2
    static let contrastScale = 1000.0

    /// - Parameter subject: subject box, normalized (0…1) with a top-left origin; nil = whole image.
    static func measure(_ gray: GrayImage, subject: CGRect? = nil) -> SharpnessMeasurement {
        let width = gray.width, height = gray.height
        guard width >= 3, height >= 3 else {
            return SharpnessMeasurement(sharpness: 0, measuredOnSubject: false, tileSharpness: 0, globalSharpness: 0)
        }
        let intensity = vDSP.integerToFloatingPoint(gray.pixels, floatingPointType: Float.self)
        let laplacian = laplacianOf(intensity, width: width, height: height)

        // Prototype method: sharpest tiles (kept for comparison).
        let grid = gridSize
        let tileVariances = (0..<(grid * grid)).map { tile in
            let rect = CGRect(x: Double(tile % grid) / Double(grid), y: Double(tile / grid) / Double(grid),
                              width: 1 / Double(grid), height: 1 / Double(grid))
            return variance(of: laplacian, width: width, height: height, in: rect)
        }
        let sharpest = tileVariances.sorted(by: >).prefix(sharpestTileCount)
        let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)

        // New method: subject only, relative to its own contrast.
        let region = subject ?? fullImage
        let edgeVariance = variance(of: laplacian, width: width, height: height, in: region)
        let contrastVariance = variance(of: intensity, width: width, height: height, in: region)
        return SharpnessMeasurement(
            sharpness: edgeVariance / max(contrastVariance, 1) * contrastScale,
            measuredOnSubject: subject != nil,
            tileSharpness: sharpest.reduce(0, +) / Double(sharpest.count),
            globalSharpness: variance(of: laplacian, width: width, height: height, in: fullImage)
        )
    }

    /// 3×3 Laplacian convolution with vImage (Accelerate).
    static func laplacianOf(_ source: [Float], width: Int, height: Int) -> [Float] {
        var source = source
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
        return laplacian
    }

    /// Variance of `values` inside a normalized top-left-origin rect, skipping the 1-pixel image border
    /// (affected by edge extension). Variance = E[x²] − E[x]².
    static func variance(of values: [Float], width: Int, height: Int, in rect: CGRect) -> Double {
        let x0 = max(1, Int((rect.minX * CGFloat(width)).rounded(.down)))
        let x1 = min(width - 1, Int((rect.maxX * CGFloat(width)).rounded(.up)))
        let y0 = max(1, Int((rect.minY * CGFloat(height)).rounded(.down)))
        let y1 = min(height - 1, Int((rect.maxY * CGFloat(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0.0, squares = 0.0
        for y in y0..<y1 {
            let rowStart = y * width
            for x in x0..<x1 {
                let value = Double(values[rowStart + x])
                sum += value
                squares += value * value
            }
        }
        let count = Double((x1 - x0) * (y1 - y0))
        let mean = sum / count
        return max(0, squares / count - mean * mean)
    }
}
