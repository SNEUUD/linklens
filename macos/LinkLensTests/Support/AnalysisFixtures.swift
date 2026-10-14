import CoreGraphics
import Foundation
@testable import LinkLens

/// Builds a PhotoAnalysis without running Vision, for pure-logic tests.
func makeAnalysis(
    _ name: String,
    sharpness: Double = 120,
    aesthetics: Double? = 0.2,
    isUtility: Bool = false,
    highlights: Double = 0,
    shadows: Double = 0,
    faces: [FaceResult] = [],
    subject: CGRect? = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2),
    date: Date? = nil
) -> PhotoAnalysis {
    PhotoAnalysis(
        photo: PhotoReference(id: UUID(), relativePath: name, captureDate: date),
        vision: VisionMeasurement(aesthetics: aesthetics, isUtility: isUtility, faces: faces, featurePrint: nil, subjectBox: subject),
        sharpness: SharpnessMeasurement(
            sharpness: sharpness, measuredOnSubject: subject != nil,
            tileSharpness: sharpness, globalSharpness: sharpness
        ),
        exposure: ExposureMeasurement(highlightClipping: highlights, shadowClipping: shadows)
    )
}

func face(quality: Double? = 0.5, eyesClosed: Bool? = false) -> FaceResult {
    FaceResult(
        boundingBox: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2),
        captureQuality: quality,
        eyeOpenness: eyesClosed.map { $0 ? 0.05 : 0.3 },
        eyesClosed: eyesClosed
    )
}

/// Checkerboard with `square`-pixel squares, alternating `dark` and `light` levels.
func checkerboard(width: Int, height: Int, square: Int, dark: UInt8 = 0, light: UInt8 = 255) -> GrayImage {
    var pixels = [UInt8](repeating: dark, count: width * height)
    for y in 0..<height {
        for x in 0..<width where (x / square + y / square) % 2 == 0 {
            pixels[y * width + x] = light
        }
    }
    return GrayImage(width: width, height: height, pixels: pixels)
}

/// Simple box blur (radius in pixels), to simulate an out-of-focus photo.
func boxBlur(_ image: GrayImage, radius: Int) -> GrayImage {
    var output = image.pixels
    for y in 0..<image.height {
        for x in 0..<image.width {
            var sum = 0, count = 0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let sx = x + dx, sy = y + dy
                    guard sx >= 0, sy >= 0, sx < image.width, sy < image.height else { continue }
                    sum += Int(image.pixels[sy * image.width + sx])
                    count += 1
                }
            }
            output[y * image.width + x] = UInt8(sum / count)
        }
    }
    return GrayImage(width: image.width, height: image.height, pixels: output)
}
