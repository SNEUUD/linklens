import Foundation
import Vision

/// Time spent in each stage, in seconds (summed over all photos in the run statistics).
public struct StageTimings: Codable, Sendable, Equatable {
    public var read = 0.0
    public var hash = 0.0
    public var pixels = 0.0
    public var thumbnail = 0.0
    public var vision = 0.0

    public static func + (lhs: StageTimings, rhs: StageTimings) -> StageTimings {
        StageTimings(
            read: lhs.read + rhs.read,
            hash: lhs.hash + rhs.hash,
            pixels: lhs.pixels + rhs.pixels,
            thumbnail: lhs.thumbnail + rhs.thumbnail,
            vision: lhs.vision + rhs.vision
        )
    }
}

/// Every measurement for one photo, before culling.
/// `Sendable` struct: it can be safely returned from a parallel task.
public struct PhotoAnalysis: Sendable {
    public var file: PhotoFile
    public var sha256: String
    public var metadata: PhotoMetadata
    public var previewSource: PreviewSource
    public var vision: VisionMeasurement
    public var sharpness: SharpnessMeasurement
    public var exposure: ExposureMeasurement
    /// Thumbnail path, relative to the output folder.
    public var thumbnail: String
    public var timings: StageTimings
}

enum PhotoAnalyzer {
    /// Analyses one photo. Reads the source file, writes only the thumbnail into `thumbsFolder`.
    static func analyze(_ file: PhotoFile, thresholds: Thresholds, thumbsFolder: URL) async throws -> PhotoAnalysis {
        var timings = StageTimings()

        let preview = try measure(&timings.read) { try PreviewLoader.load(url: file.url) }
        try Task.checkCancellation()

        let sha256 = try measure(&timings.hash) { try FileHasher.sha256(of: file.url) }
        try Task.checkCancellation()

        // Vision first: the sharpness is measured on the subject it finds.
        let clock = ContinuousClock()
        let visionStart = clock.now
        let vision = try await VisionAnalyzer.analyze(preview.image, thresholds: thresholds)
        timings.vision = visionStart.duration(to: clock.now).seconds
        try Task.checkCancellation()

        let (sharpness, exposure) = try measure(&timings.pixels) {
            let gray = try GrayImage(image: preview.image, longSide: thresholds.analysisLongSide)
            return (Sharpness.measure(gray, subject: vision.subjectBox), Exposure.measure(gray))
        }

        let thumbnailName = ThumbnailWriter.fileName(for: file.relativePath)
        try measure(&timings.thumbnail) {
            try ThumbnailWriter.write(preview.image, to: thumbsFolder.appending(path: thumbnailName))
        }

        return PhotoAnalysis(
            file: file,
            sha256: sha256,
            metadata: preview.metadata,
            previewSource: preview.source,
            vision: vision,
            sharpness: sharpness,
            exposure: exposure,
            thumbnail: "thumbs/" + thumbnailName,
            timings: timings
        )
    }
}
