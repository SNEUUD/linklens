import CoreGraphics
import Foundation

/// Every measurement for one photo, before culling.
/// `Sendable` = safe to hand from one task to another (a plain value, no shared mutable state):
/// that is what lets a parallel task return it.
struct PhotoAnalysis: Sendable {
    var photo: PhotoReference
    var vision: VisionMeasurement
    var sharpness: SharpnessMeasurement
    var exposure: ExposureMeasurement
}

enum PhotoAnalyzer {
    /// Analyses one photo of `folder` (already opened with its security-scoped bookmark).
    /// The file is only read.
    static func analyze(_ photo: PhotoReference, in folder: URL, thresholds: CullingThresholds) async throws -> PhotoAnalysis {
        let image = try PreviewLoader.load(url: folder.appending(path: photo.relativePath))
        try Task.checkCancellation()

        // Vision first: the sharpness is measured on the subject it finds.
        let vision = try await VisionAnalyzer.analyze(image, thresholds: thresholds)
        try Task.checkCancellation()

        let gray = try GrayImage(image: image, longSide: thresholds.analysisLongSide)
        return PhotoAnalysis(
            photo: photo,
            vision: vision,
            sharpness: Sharpness.measure(gray, subject: vision.subjectBox),
            exposure: Exposure.measure(gray)
        )
    }
}
