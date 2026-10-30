import Accelerate
import CoreGraphics
import Foundation

struct SharpnessMeasurement: Sendable, Equatable {
    /// How crisp the edges of the sharpest zones are (×100). Around 100 for a sharp photo, much lower
    /// when blurry. Each zone is judged on its own contrast, so a dark car, a large uniform sky or a
    /// shallow depth of field do not lower the score: only the width of the edges counts.
    var sharpness: Double
    /// True if `sharpness` was measured on the subject, false if on the whole image.
    var measuredOnSubject: Bool
    /// How sharp the sharpest part of the image around the subject is (zones outside its box,
    /// 90th percentile). High when the focus is on something else than the subject Vision found
    /// (a blurry spectator in front of a sharp car). 0 when measured on the whole image.
    var surroundingSharpness: Double
    /// Zones with enough detail to be judged. Below `Sharpness.minZones` (black frame, empty sky)
    /// the photo has nothing to judge and gets no blur verdict.
    var detailedZones: Int

    var isMeasurable: Bool { detailedZones >= Sharpness.minZones }
}

/// Blur detection, zone by zone and direction by direction.
///
/// The image is cut into small square zones. In each zone with a real edge, the strength of the second
/// derivative (it peaks on crisp edges) is divided by the strength of the first derivative (the contrast
/// of the edge). For one edge, this ratio is about 2 ÷ its width in pixels: it does not depend on the
/// contrast, nor on how many edges the zone holds.
///
/// Horizontal and vertical edges are measured apart: a car moving sideways smears only the vertical
/// edges (its horizontal ones stay crisp), so the score is the worse of the two directions.
/// In each direction, a high percentile of the zones is used: a photo is sharp when most of its subject
/// has crisp edges, even if the background is soft, and one crisp wire in front does not make it sharp.
enum Sharpness {
    /// Side of a zone, in pixels of the analysed image (`CullingThresholds.analysisLongSide`).
    static let zoneSize = 32
    /// A zone is judged only if its strongest edge reaches this many grey levels per pixel:
    /// flatter zones are sky, bokeh or noise.
    static let minEdgeStrength: Float = 6
    /// In a zone, only pixels with a derivative at least this share of the zone's strongest one are edge pixels.
    static let edgeShare: Float = 0.3
    /// Percentile of the zones used in each direction (0.75 = sharper than three zones out of four).
    static let zonePercentile = 0.75
    /// Around the subject only the sharpest zones count: is something else in focus?
    static let surroundingPercentile = 0.9
    /// Zones needed in each direction to judge the photo at all.
    static let minZones = 3
    static let scoreScale = 100.0

    /// - Parameter subject: subject box, normalized (0…1) with a top-left origin; nil = whole image.
    ///   When the subject holds too few detailed zones, the whole image is measured instead.
    static func measure(_ gray: GrayImage, subject: CGRect? = nil) -> SharpnessMeasurement {
        let width = gray.width, height = gray.height
        guard width >= 8, height >= 8 else {
            return SharpnessMeasurement(sharpness: 0, measuredOnSubject: false, surroundingSharpness: 0, detailedZones: 0)
        }
        let intensity = vDSP.integerToFloatingPoint(gray.pixels, floatingPointType: Float.self)
        // Derivatives across each direction, smoothed along the other one (like a Sobel filter)
        // so sensor noise (high ISO) does not look like fine sharp detail.
        let horizontal = Derivatives(
            first: convolve(intensity, width: width, height: height, kernel: [-1, 0, 1, -2, 0, 2, -1, 0, 1].map { $0 / 8 }),
            second: convolve(intensity, width: width, height: height, kernel: [1, -2, 1, 2, -4, 2, 1, -2, 1].map { $0 / 4 })
        )
        let vertical = Derivatives(
            first: convolve(intensity, width: width, height: height, kernel: [-1, -2, -1, 0, 0, 0, 1, 2, 1].map { $0 / 8 }),
            second: convolve(intensity, width: width, height: height, kernel: [1, 2, 1, -2, -4, -2, 1, 2, 1].map { $0 / 4 })
        )

        // A nested function: like a closure declared inside `measure`, it sees `horizontal` and `vertical`.
        func measure(in rect: CGRect, excluding hole: CGRect? = nil, percentile rank: Double = zonePercentile) -> (score: Double, zones: Int) {
            let across = zoneScores(horizontal, width: width, height: height, in: rect, excluding: hole)
            let down = zoneScores(vertical, width: width, height: height, in: rect, excluding: hole)
            let zones = min(across.count, down.count)
            guard zones >= minZones else { return (0, zones) }
            return (min(percentile(across, rank), percentile(down, rank)) * scoreScale, zones)
        }

        let wholeImage = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let subject {
            let onSubject = measure(in: subject)
            if onSubject.zones >= minZones {
                let around = measure(in: wholeImage, excluding: subject, percentile: surroundingPercentile)
                return SharpnessMeasurement(
                    sharpness: onSubject.score, measuredOnSubject: true,
                    surroundingSharpness: around.score, detailedZones: onSubject.zones
                )
            }
        }
        let whole = measure(in: wholeImage)
        return SharpnessMeasurement(
            sharpness: whole.score, measuredOnSubject: false,
            surroundingSharpness: 0, detailedZones: whole.zones
        )
    }

    /// First and second derivative of the image in one direction.
    struct Derivatives {
        var first: [Float]
        var second: [Float]
    }

    static func percentile(_ values: [Double], _ rank: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * rank))]
    }

    /// Edge crispness (second ÷ first derivative on the edge pixels) of every zone of `rect` holding an
    /// edge, leaving out the zones that touch `hole`.
    static func zoneScores(
        _ derivatives: Derivatives, width: Int, height: Int, in rect: CGRect, excluding hole: CGRect? = nil
    ) -> [Double] {
        // Pixel bounds of the rect, without the 2-pixel image border (affected by edge extension).
        let x0 = max(2, Int((rect.minX * CGFloat(width)).rounded(.down)))
        let x1 = min(width - 2, Int((rect.maxX * CGFloat(width)).rounded(.up)))
        let y0 = max(2, Int((rect.minY * CGFloat(height)).rounded(.down)))
        let y1 = min(height - 2, Int((rect.maxY * CGFloat(height)).rounded(.up)))
        var scores: [Double] = []
        // `stride(from:to:by:)` is like a `for (let y = y0; y < y1; y += zoneSize)` loop.
        for zoneY in stride(from: y0, to: y1, by: zoneSize) {
            for zoneX in stride(from: x0, to: x1, by: zoneSize) {
                let zoneX1 = min(zoneX + zoneSize, x1), zoneY1 = min(zoneY + zoneSize, y1)
                // A sliver at the right or bottom of the rect is too small to judge.
                guard (zoneX1 - zoneX) * 2 >= zoneSize, (zoneY1 - zoneY) * 2 >= zoneSize else { continue }
                if let hole {
                    let zone = CGRect(
                        x: Double(zoneX) / Double(width), y: Double(zoneY) / Double(height),
                        width: Double(zoneX1 - zoneX) / Double(width), height: Double(zoneY1 - zoneY) / Double(height)
                    )
                    if zone.intersects(hole) { continue }
                }
                var strongest: Float = 0
                for y in zoneY..<zoneY1 {
                    for x in zoneX..<zoneX1 { strongest = max(strongest, abs(derivatives.first[y * width + x])) }
                }
                guard strongest >= minEdgeStrength else { continue }
                let floor = strongest * edgeShare
                var secondSum: Float = 0, firstSum: Float = 0
                for y in zoneY..<zoneY1 {
                    for x in zoneX..<zoneX1 {
                        let first = abs(derivatives.first[y * width + x])
                        guard first >= floor else { continue }
                        secondSum += abs(derivatives.second[y * width + x])
                        firstSum += first
                    }
                }
                scores.append(Double(secondSum / firstSum))
            }
        }
        return scores
    }

    /// 3×3 convolution with vImage (Accelerate).
    static func convolve(_ source: [Float], width: Int, height: Int, kernel: [Float]) -> [Float] {
        var source = source
        var destination = [Float](repeating: 0, count: width * height)
        source.withUnsafeMutableBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
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
        return destination
    }
}
