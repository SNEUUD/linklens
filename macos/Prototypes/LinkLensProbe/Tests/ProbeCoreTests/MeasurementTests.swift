import CoreGraphics
import Foundation
import Testing
@testable import ProbeCore

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
        #expect(openness < Thresholds().eyeClosedOpenness)
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
        #expect(sharpValue > Thresholds().blurReview)
        #expect(blurredValue < sharpValue / 5)
    }

    @Test func outOfFocusBackgroundDoesNotHideASharpSubject() {
        // Left quarter sharp, the rest flat (like a subject in front of a blurry background).
        var image = GrayImage(width: 128, height: 128, pixels: [UInt8](repeating: 128, count: 128 * 128))
        let board = checkerboard(width: 128, height: 128, square: 4)
        for y in 0..<128 { for x in 0..<32 { image.pixels[y * 128 + x] = board.pixels[y * 128 + x] } }
        let result = Sharpness.measure(image)
        #expect(result.sharpness > result.globalSharpness * 2)
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

@Suite("EXIF dates")
struct ExifDateTests {
    @Test func parsesDateAndSubseconds() throws {
        let base = try #require(PreviewLoader.parseExifDate("2026:09:20 14:40:57", subseconds: nil))
        let withFraction = try #require(PreviewLoader.parseExifDate("2026:09:20 14:40:57", subseconds: "25"))
        #expect(abs(withFraction.timeIntervalSince(base) - 0.25) < 0.0001)
        #expect(PreviewLoader.parseExifDate("pas une date", subseconds: nil) == nil)
    }
}
