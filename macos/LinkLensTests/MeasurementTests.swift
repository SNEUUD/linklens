import CoreGraphics
import Foundation
import Testing
@testable import LinkLens

@Suite("Eye openness")
struct EyeStateTests {
    /// Eye contour as an ellipse (8 points), optionally rotated (tilted head).
    func eye(width: Double, height: Double, angleDegrees: Double = 0) -> [CGPoint] {
        let angle = angleDegrees * .pi / 180
        return (0..<8).map { step in
            let t = Double(step) * .pi / 4
            let x = width / 2 * cos(t), y = height / 2 * sin(t)
            return CGPoint(x: 100 + x * cos(angle) - y * sin(angle), y: 100 + x * sin(angle) + y * cos(angle))
        }
    }

    @Test func openEye() throws {
        let openness = try #require(EyeState.openness(of: eye(width: 30, height: 10)))
        #expect(abs(openness - 1.0 / 3.0) < 0.01)
    }

    @Test func closedEye() throws {
        let openness = try #require(EyeState.openness(of: eye(width: 30, height: 2)))
        #expect(openness < CullingThresholds().eyeClosedOpenness)
    }

    @Test func tiltedHeadGivesSameOpenness() throws {
        let straight = try #require(EyeState.openness(of: eye(width: 30, height: 10)))
        let tilted = try #require(EyeState.openness(of: eye(width: 30, height: 10, angleDegrees: 30)))
        #expect(abs(straight - tilted) < 0.02)
    }

    @Test func tooFewPoints() {
        #expect(EyeState.openness(of: [.zero, CGPoint(x: 1, y: 0)]) == nil)
    }
}

@Suite("Blur (Laplacian variance)")
struct SharpnessTests {
    @Test func uniformImageHasNoSharpness() {
        let flat = GrayImage(width: 64, height: 64, pixels: [UInt8](repeating: 128, count: 64 * 64))
        #expect(Sharpness.measure(flat).sharpness == 0)
    }

    @Test func blurLowersSharpness() {
        let sharp = checkerboard(width: 128, height: 128, square: 8)
        let blurred = boxBlur(sharp, radius: 3)
        let sharpValue = Sharpness.measure(sharp).sharpness
        let blurredValue = Sharpness.measure(blurred).sharpness
        #expect(sharpValue > CullingThresholds().blurReview)
        #expect(blurredValue < sharpValue / 5)
    }

    @Test func sharpTilesStandOutFromAFlatBackground() {
        let result = Sharpness.measure(leftQuarterSharp())
        #expect(result.tileSharpness > result.globalSharpness * 2)
    }

    @Test func blurrySubjectInFrontOfASharpBackground() {
        // Like DSC04301: the background (fence, track lines) is sharp, the car is soft.
        let sharp = checkerboard(width: 128, height: 128, square: 8)
        let soft = boxBlur(sharp, radius: 3)
        var image = sharp
        for y in 0..<128 { for x in 0..<32 { image.pixels[y * 128 + x] = soft.pixels[y * 128 + x] } }

        let onSubject = Sharpness.measure(image, subject: CGRect(x: 0, y: 0, width: 0.25, height: 1))
        let onImage = Sharpness.measure(image)
        #expect(onSubject.measuredOnSubject && !onImage.measuredOnSubject)
        #expect(onSubject.sharpness < onImage.sharpness / 2)
    }

    @Test func contrastDoesNotChangeTheScore() {
        // Same pattern, dark and low-contrast (like a black car) vs. bright and high-contrast.
        let bright = Sharpness.measure(checkerboard(width: 128, height: 128, square: 8))
        let dark = Sharpness.measure(checkerboard(width: 128, height: 128, square: 8, dark: 10, light: 50))
        #expect(dark.globalSharpness < bright.globalSharpness / 10)
        #expect(abs(dark.sharpness - bright.sharpness) / bright.sharpness < 0.05)
    }

    /// Left quarter: fine checkerboard; the rest: flat grey.
    func leftQuarterSharp() -> GrayImage {
        var image = GrayImage(width: 128, height: 128, pixels: [UInt8](repeating: 128, count: 128 * 128))
        let board = checkerboard(width: 128, height: 128, square: 4)
        for y in 0..<128 { for x in 0..<32 { image.pixels[y * 128 + x] = board.pixels[y * 128 + x] } }
        return image
    }
}

@Suite("Exposure")
struct ExposureTests {
    @Test func clippingShares() {
        // 10 % white, 40 % black, 50 % mid-grey.
        let pixels = [UInt8](repeating: 255, count: 10) + [UInt8](repeating: 0, count: 40) + [UInt8](repeating: 128, count: 50)
        let result = Exposure.measure(GrayImage(width: 10, height: 10, pixels: pixels))
        #expect(abs(result.highlightClipping - 0.10) < 0.0001)
        #expect(abs(result.shadowClipping - 0.40) < 0.0001)
    }
}
