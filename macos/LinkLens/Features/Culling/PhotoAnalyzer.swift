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
    /// Camera, lens and settings (EXIF), for the inspector.
    var capture = CaptureInfo()
}

enum PhotoAnalyzer {
    /// Analyses one photo of `folder` (already opened with its security-scoped bookmark).
    /// The file is only read.
    static func analyze(_ photo: PhotoReference, in folder: URL, thresholds: CullingThresholds) async throws -> PhotoAnalysis {
        let url = folder.appending(path: photo.relativePath)
        let image = try PreviewLoader.load(url: url)
        try Task.checkCancellation()

        // Vision first: the sharpness is measured on the subject it finds.
        let vision = try await VisionAnalyzer.analyze(image, thresholds: thresholds)
        try Task.checkCancellation()

        let gray = try GrayImage(image: image, longSide: thresholds.analysisLongSide)
        return PhotoAnalysis(
            photo: photo,
            vision: vision,
            sharpness: Sharpness.measure(gray, subject: vision.subjectBox),
            exposure: Exposure.measure(gray),
            // Only the file header: a few milliseconds next to Vision.
            capture: PhotoMetadataReader.read(url: url).capture
        )
    }
}
