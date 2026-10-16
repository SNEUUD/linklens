import AVFoundation
import CoreGraphics
import Foundation

/// Reads videos with AVFoundation: metadata for the catalogue and a still frame for thumbnails.
/// The file is only read. Formats AVFoundation cannot open (AVCHD .mts) give `PhotoMetadata.unknown`
/// and no image: the video is still listed in the gallery.
enum VideoReader {
    /// Recording date, from the file metadata, displayed size (rotation applied) and length.
    static func metadata(url: URL) async -> PhotoMetadata {
        let asset = AVURLAsset(url: url)
        // `try?` turns an error into nil (like a `catch` returning undefined): a missing value is not fatal.
        let creationDate = try? await asset.load(.creationDate)?.load(.dateValue)
        let duration = await duration(of: asset)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else {
            return PhotoMetadata(captureDate: creationDate, pixelWidth: 0, pixelHeight: 0, duration: duration)
        }
        let displayed = size.applying(transform)
        return PhotoMetadata(
            captureDate: creationDate,
            pixelWidth: Int(abs(displayed.width).rounded()),
            pixelHeight: Int(abs(displayed.height).rounded()),
            duration: duration
        )
    }

    /// Length in seconds, nil if AVFoundation cannot tell (AVCHD .mts, damaged file).
    static func duration(of asset: AVURLAsset) async -> Double? {
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// A frame one second in (or the middle of a shorter clip), long side ≤ `maxPixelSize`.
    static func frame(url: URL, maxPixelSize: Int) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let time = CMTimeMinimum(CMTime(seconds: 1, preferredTimescale: 600), CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2))
        return try await generator.image(at: time).image
    }
}
