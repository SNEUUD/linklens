import AVFoundation
import CoreVideo
import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// F6: export of the videos of an SD card (H.264 or HEVC, one at a time, next to the photos).
/// Every video is made by the test itself, in a temporary folder.
@MainActor
struct VideoExportTests {
    @Test(arguments: VideoExportPreset.allCases)
    func bothFormatsWriteAPlayableMP4WithTheirCodec(preset: VideoExportPreset) async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        try await writeTestVideo(in: photos, "C0001.MOV", frames: 20)
        let before = try photos.snapshot()

        let summary = try await PhotoExporter().export(
            request(photos, ["C0001.MOV"], preset: .printJPEG, videoPreset: preset, destination: destination)
        )

        #expect(summary.failures.isEmpty)
        #expect(summary.exportedFiles.map(\.lastPathComponent) == ["C0001.mp4"])
        let file = try #require(summary.exportedFiles.first)
        let asset = AVURLAsset(url: file)
        #expect(try await asset.load(.isPlayable))
        #expect(try await codec(of: asset) == (preset == .compatible ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC))
        let frame = try await VideoReader.frame(url: file, maxPixelSize: 160)
        #expect(frame.width == 160)
        #expect(abs((await VideoReader.duration(of: asset) ?? 0) - 20.0 / 30) < 0.1)
        #expect(try destination.fileNames() == ["C0001.mp4"], "no temporary file left")
        #expect(try photos.snapshot() == before, "the original is only read")
    }

    @Test func thePositionIsRemovedOnlyWithTheWebPreset() async throws {
        let photos = try TestFolder()
        defer { photos.remove() }
        try await writeTestVideo(in: photos, "clip.mov", frames: 10, withLocation: true)
        #expect(try await location(of: AVURLAsset(url: photos.url.appending(path: "clip.mov"))) != nil, "the test video has a position")

        var positions: [ExportPreset: String?] = [:]
        var dates: [ExportPreset: String?] = [:]
        for preset in [ExportPreset.webJPEG, .printJPEG] {
            let destination = try TestFolder()
            defer { destination.remove() }
            let summary = try await PhotoExporter().export(
                request(photos, ["clip.mov"], preset: preset, videoPreset: .light, destination: destination)
            )
            let asset = AVURLAsset(url: try #require(summary.exportedFiles.first))
            positions[preset] = try await location(of: asset)
            dates[preset] = try await creationDate(of: asset)
        }

        #expect(positions[.webJPEG] == .some(nil), "JPEG pour le web: no GPS position")
        #expect(positions[.printJPEG]??.hasPrefix("+48.") == true)
        #expect(dates[.webJPEG]??.hasPrefix("2026-09-20") == true, "the recording date stays")
        #expect(dates[.printJPEG]??.hasPrefix("2026-09-20") == true)
    }

    @Test func cancellingStopsTheVideoAndLeavesNoFile() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        // Noise is slow to encode: HEVC takes long enough to be cancelled in the middle.
        try await writeTestVideo(in: photos, "long.mov", width: 1280, height: 720, frames: 240, noise: true)
        let box = VideoTaskBox()
        let fractions = FractionLog()

        box.task = Task {
            try await PhotoExporter().export(
                request(photos, ["long.mov"], preset: .printJPEG, videoPreset: .light, destination: destination)
            ) { progress in
                // The bar moves during the video: cancel as soon as it has started.
                if let fraction = progress.currentFileFraction, fraction > 0 {
                    fractions.values.append(fraction)
                    box.task?.cancel()
                }
            }
        }
        let summary = try await #require(box.task).value

        #expect(summary.wasCancelled)
        #expect(summary.exportedFiles.isEmpty)
        #expect(summary.failures.isEmpty, "a cancelled video is not a failure")
        #expect(fractions.values.first.map { $0 < 1 } == true)
        #expect(try destination.fileNames() == [], "no half-written video, not even hidden")
    }

    @Test func anUnsupportedVideoIsListedAndTheRestExported() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        try photos.writeJPEG("DSC0001.JPG", width: 300, height: 200)
        try await writeTestVideo(in: photos, "C0002.MP4", frames: 10)
        try photos.writeFile("PRIVATE/AVCHD/00000.MTS", contents: "AVCHD stream AVFoundation cannot read")
        try photos.writeFile("damaged.mov")

        let summary = try await PhotoExporter().export(
            request(photos, ["DSC0001.JPG", "PRIVATE/AVCHD/00000.MTS", "C0002.MP4", "damaged.mov"],
                    preset: .heic, videoPreset: .compatible, destination: destination)
        )

        #expect(summary.exportedFiles.map(\.lastPathComponent) == ["DSC0001.heic", "C0002.mp4"])
        #expect(Set(summary.failures.map(\.relativePath)) == ["PRIVATE/AVCHD/00000.MTS", "damaged.mov"])
        let message = try #require(summary.failures.first { $0.relativePath.hasSuffix(".MTS") }?.message)
        #expect(message == "« 00000.MTS » — Format non pris en charge : copiez ce fichier tel quel depuis le Finder.")
        #expect(try destination.fileNames() == ["C0002.mp4", "DSC0001.heic"])
    }

    @Test func anExistingFileIsNeverReplaced() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        try await writeTestVideo(in: photos, "clip.mov", frames: 10)
        // A photo of the same name goes out as « clip.jpg »: no clash with the video.
        try photos.writeJPEG("clip.jpg", width: 300, height: 200)
        let existing = try destination.writeFile("clip.mp4", contents: "already here")

        let summary = try await PhotoExporter().export(
            request(photos, ["clip.jpg", "clip.mov"], preset: .webJPEG, videoPreset: .compatible, destination: destination)
        )

        #expect(summary.exportedFiles.map(\.lastPathComponent) == ["clip.jpg", "clip (2).mp4"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "already here")
        #expect(try destination.fileNames() == ["clip (2).mp4", "clip.jpg", "clip.mp4"])
    }

    @Test func photosAndVideosAreCountedTogether() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        try photos.writeJPEG("a.jpg", width: 300, height: 200)
        try photos.writeJPEG("b.jpg", width: 300, height: 200)
        try await writeTestVideo(in: photos, "c.mov", frames: 10)
        let completed = ProgressCounts()

        let summary = try await PhotoExporter(concurrency: 2).export(
            request(photos, ["a.jpg", "c.mov", "b.jpg"], preset: .webJPEG, videoPreset: .compatible, destination: destination)
        ) { progress in
            completed.values.append(progress.completed)
            #expect(progress.total == 3)
            #expect(progress.fraction <= 1)
        }

        #expect(summary.exportedFiles.map(\.lastPathComponent) == ["a.jpg", "c.mp4", "b.jpg"], "in the order asked for")
        #expect(completed.values.first == 0)
        #expect(completed.values.last == 3)
        #expect(completed.values == completed.values.sorted(), "never goes back")
    }

    // MARK: - Progress, names, pill

    @Test func theCurrentVideoMovesTheBar() {
        var progress = ExportProgress(galleryId: UUID(), preset: .webJPEG, completed: 2, total: 4)
        #expect(progress.fraction == 0.5)
        progress.currentFileFraction = 0.5
        #expect(progress.fraction == 0.625)

        let activity = Activity.export(progress, startedAt: .now)
        #expect(activity.fraction == 0.625)
        #expect(activity.text == "Export « JPEG pour le web » · 2 sur 4", "the count stays in whole files")
    }

    @Test func eachFileGetsTheExtensionOfItsFormat() {
        let names = ExportNaming.plan(
            [("IMG_0001.JPG", "jpg"), ("IMG_0001.MOV", "mp4"), ("Jour 2/IMG_0001.MP4", "mp4")], existingNames: []
        )

        #expect(names == ["IMG_0001.jpg", "IMG_0001.mp4", "IMG_0001 (2).mp4"])
    }

    @Test func theFinishedExportCountsPhotosAndVideosApart() {
        let destination = URL(filePath: "/Users/chris/Desktop/Export", directoryHint: .isDirectory)
        let files = ["a.jpg", "b.jpg", "C0001.mp4"].map { destination.appending(path: $0) }
        var summary = ExportSummary(
            galleryId: UUID(), preset: .webJPEG, destination: destination, exportedFiles: files, failures: [], wasCancelled: false
        )

        #expect(Activity.exportFinished(summary, at: .now).text == "Export terminé : 2 photos et 1 vidéo dans « Export »")
        summary.exportedFiles.append(destination.appending(path: "C0002.mp4"))
        summary.wasCancelled = true
        #expect(Activity.exportFinished(summary, at: .now).text == "Export annulé : 2 photos et 2 vidéos dans « Export »")
    }

    // MARK: - Scopes

    @Test func videosGoWithThePhotosToKeepUnlessTheUserRejectedThem() throws {
        let container = try makeInMemoryContainer()
        let files = ["a.ARW", "b.ARW", "c.ARW", "C0001.MP4", "C0002.MP4", "C0003.MP4", "C0004.MP4"]
        let photos = files.map { makePhoto($0, in: container) }
        photos[0].cullingVerdictRaw = CullingVerdict.keep.rawValue
        photos[1].cullingVerdictRaw = CullingVerdict.review.rawValue
        photos[2].cullingVerdictRaw = CullingVerdict.reject.rawValue
        // C0001: never sorted. C0002: rejected by the user. C0003: « À revoir » by the user. C0004: kept.
        photos[4].userVerdictRaw = CullingVerdict.reject.rawValue
        photos[5].userVerdictRaw = CullingVerdict.review.rawValue
        photos[6].userVerdictRaw = CullingVerdict.keep.rawValue

        let keep = ExportScope.keep.photos(from: photos, selectedPhotoId: nil)
        let all = ExportScope.all.photos(from: photos, selectedPhotoId: nil)

        #expect(keep.map(\.relativePath) == ["a.ARW", "C0001.MP4", "C0003.MP4", "C0004.MP4"])
        #expect(ExportCounts(keep) == ExportCounts(photos: 1, videos: 3))
        #expect(ExportCounts(all) == ExportCounts(photos: 3, videos: 4))
        #expect(ExportScope.defaultScope(for: photos) == .keep)
    }

    @Test func videosAloneDoNotMakeAScopeToKeep() throws {
        let container = try makeInMemoryContainer()
        let photos = ["a.ARW", "C0001.MP4"].map { makePhoto($0, in: container) }
        photos[1].userVerdictRaw = CullingVerdict.keep.rawValue // a video kept by the user, no photo to keep

        #expect(ExportScope.defaultScope(for: photos) == .all)
    }

    @Test func labelsCountPhotosAndVideosApart() throws {
        let container = try makeInMemoryContainer()
        let video = makePhoto("C0001.MP4", in: container)

        #expect(ExportSheet.label(for: .keep, counts: ExportCounts(photos: 12, videos: 0), selected: nil) == "Les photos à garder (12)")
        #expect(ExportSheet.label(for: .keep, counts: ExportCounts(photos: 12, videos: 3), selected: nil)
            == "Les photos à garder (12) et les vidéos (3)")
        #expect(ExportSheet.label(for: .all, counts: ExportCounts(photos: 52, videos: 0), selected: nil) == "Toutes les photos (52)")
        #expect(ExportSheet.label(for: .all, counts: ExportCounts(photos: 52, videos: 3), selected: nil) == "Toutes (52 photos, 3 vidéos)")
        #expect(ExportSheet.label(for: .all, counts: ExportCounts(photos: 1, videos: 1), selected: nil) == "Toutes (1 photo, 1 vidéo)")
        #expect(ExportSheet.label(for: .selection, counts: ExportCounts(photos: 0, videos: 1), selected: video)
            == "La vidéo sélectionnée (C0001.MP4)")
    }

    // MARK: - Helpers

    private func request(
        _ photos: TestFolder, _ paths: [String], preset: ExportPreset, videoPreset: VideoExportPreset, destination: TestFolder
    ) -> ExportRequest {
        ExportRequest(
            galleryId: UUID(),
            galleryName: "Séance",
            folderPath: photos.url.path,
            folderBookmark: (try? FolderBookmark.create(for: photos.url)) ?? Data(),
            items: paths.map { ExportItem(photoId: UUID(), relativePath: $0) },
            preset: preset,
            destination: destination.url,
            videoPreset: videoPreset
        )
    }

    private func makePhoto(_ path: String, in container: ModelContainer) -> Photo {
        let draft = PhotoDraft(
            file: PhotoFile(url: URL(filePath: "/tmp/\(path)"), relativePath: path, fileSize: 1),
            metadata: .unknown,
            importedAt: Date()
        )
        let photo = Photo(draft: draft)
        container.mainContext.insert(photo)
        return photo
    }
}

// MARK: - Test videos

/// Progress seen by a test. Classes: a `@Sendable` closure cannot change a local `var`.
@MainActor
private final class FractionLog {
    var values: [Double] = []
}

@MainActor
private final class ProgressCounts {
    var values: [Int] = []
}

@MainActor
private final class VideoTaskBox {
    var task: Task<ExportSummary, Error>?
}

private extension TestFolder {
    /// Every file of the folder, hidden ones included (a temporary file would be listed), sorted.
    func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

/// Writes a real H.264 QuickTime video of `frames` frames at 30 per second, optionally with a
/// recording date and a GPS position (as a camera or an iPhone writes them).
private func writeTestVideo(
    in folder: TestFolder,
    _ relativePath: String,
    width: Int = 320,
    height: Int = 240,
    frames: Int,
    withLocation: Bool = false,
    noise: Bool = false
) async throws {
    let file = folder.url.appending(path: relativePath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
    if withLocation {
        writer.metadata = [
            metadataItem(.quickTimeMetadataKeyLocationISO6709, "+48.0000+000.2000/"),
            metadataItem(.quickTimeMetadataKeyCreationDate, "2026-09-20T14:40:57+0200"),
        ]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    try #require(writer.startWriting(), "\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)

    // A few distinct images, shown in turn: filling a buffer per frame would be slow in a test build.
    let images = try (0..<4).map { try makePixelBuffer(width: width, height: height, seed: $0, noise: noise) }
    for index in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(adaptor.append(images[index % images.count], withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
}

private func metadataItem(_ key: AVMetadataKey, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = key.rawValue as NSString
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

/// A plain colour, or random noise (hard to compress, so slow to encode).
private func makePixelBuffer(width: Int, height: Int, seed: Int, noise: Bool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(pixels))
    let length = CVPixelBufferGetBytesPerRow(pixels) * height
    if noise {
        arc4random_buf(base, length)
    } else {
        memset(base, Int32(40 + seed * 50), length)
    }
    return pixels
}

private func codec(of asset: AVURLAsset) async throws -> FourCharCode {
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    return CMFormatDescriptionGetMediaSubType(format)
}

/// The GPS position stored in the file (QuickTime or MP4 spelling), nil if there is none.
private func location(of asset: AVURLAsset) async throws -> String? {
    try await stringValue(in: asset, identifiers: [.quickTimeMetadataLocationISO6709, AVMetadataIdentifier(rawValue: "uiso/loci")])
}

private func creationDate(of asset: AVURLAsset) async throws -> String? {
    try await stringValue(in: asset, identifiers: [.quickTimeMetadataCreationDate, AVMetadataIdentifier(rawValue: "uiso/date")])
}

private func stringValue(in asset: AVURLAsset, identifiers: [AVMetadataIdentifier]) async throws -> String? {
    for item in try await asset.load(.metadata) where item.identifier.map(identifiers.contains) == true {
        if let value = try await item.load(.stringValue) { return value }
    }
    return nil
}
