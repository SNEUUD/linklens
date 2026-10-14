import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import LinkLens

/// F6: names of the exported files.
struct ExportNamingTests {
    @Test func keepsTheOriginalNameWithTheNewExtension() {
        let names = ExportNaming.plan(["DSC04297.ARW", "Jour 2/IMG_0001.HEIC"], fileExtension: "jpg", existingNames: [])

        #expect(names == ["DSC04297.jpg", "IMG_0001.jpg"])
    }

    @Test func neverReusesTheNameOfAnExistingFile() {
        // Compared without case, like the Mac's file system.
        let names = ExportNaming.plan(["DSC04297.ARW"], fileExtension: "jpg", existingNames: ["dsc04297.JPG", "DSC04297 (2).jpg"])

        #expect(names == ["DSC04297 (3).jpg"])
    }

    @Test func numbersTheSameNameWithinOneExport() {
        // Two folders of the same gallery, or a RAW + JPEG pair.
        let names = ExportNaming.plan(
            ["Jour 1/IMG_0001.JPG", "Jour 2/IMG_0001.JPG", "IMG_0001.ARW"], fileExtension: "heic", existingNames: []
        )

        #expect(names == ["IMG_0001.heic", "IMG_0001 (2).heic", "IMG_0001 (3).heic"])
    }
}

/// F6: conversion of one photo (size, orientation, format, metadata).
struct PhotoConverterTests {
    @Test func targetSizeReducesTheLongSideOnly() {
        #expect(PhotoConverter.targetSize(width: 6000, height: 4000, maxLongSide: 2048) == (2048, 1365))
        #expect(PhotoConverter.targetSize(width: 4000, height: 6000, maxLongSide: 2048) == (1365, 2048))
        #expect(PhotoConverter.targetSize(width: 800, height: 600, maxLongSide: 2048) == (800, 600))
        #expect(PhotoConverter.targetSize(width: 6000, height: 4000, maxLongSide: nil) == (6000, 4000))
    }

    @Test func webPresetReducesTheLongSideInSRGB() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let source = try writeSourceJPEG(in: folder, "big.jpg", width: 3000, height: 2000)
        let output = folder.url.appending(path: "big-web.jpg")

        let result = try PhotoConverter.convert(source, to: output, settings: ExportPreset.webJPEG.settings, context: CIContextForTests.shared)

        #expect(result == PhotoConverter.Result(width: 2048, height: 1365))
        let written = try readImage(output)
        #expect(written.type == UTType.jpeg.identifier)
        #expect(written.image.width == 2048)
        #expect(written.image.height == 1365)
        #expect(written.image.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func printPresetKeepsTheFullResolutionAt300Dpi() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let source = try writeSourceJPEG(in: folder, "big.jpg", width: 3000, height: 2000)
        let output = folder.url.appending(path: "big-print.jpg")

        try PhotoConverter.convert(source, to: output, settings: ExportPreset.printJPEG.settings, context: CIContextForTests.shared)

        let written = try readImage(output)
        #expect(written.image.width == 3000)
        #expect(written.image.height == 2000)
        #expect((written.properties[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue == 300)
    }

    @Test func appliesTheExifOrientation() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        // Stored landscape, left half red, orientation 6 = "rotate 90° clockwise to display":
        // the photo is a portrait whose top half is red.
        let source = try writeSourceJPEG(in: folder, "portrait.jpg", width: 300, height: 200, orientation: 6, redLeftHalf: true)
        let output = folder.url.appending(path: "portrait.tif")

        try PhotoConverter.convert(source, to: output, settings: ExportPreset.tiff.settings, context: CIContextForTests.shared)

        let written = try readImage(output)
        #expect(written.image.width == 200)
        #expect(written.image.height == 300)
        #expect((written.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let top = try pixel(of: written.image, x: 100, y: 30)
        let bottom = try pixel(of: written.image, x: 100, y: 270)
        #expect(top.red > 200 && top.blue < 60)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }

    @Test func keepsTheDateAndCameraButDropsThePositionForTheWeb() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let source = try writeSourceJPEG(in: folder, "shot.jpg", width: 400, height: 300, withMetadata: true)
        let web = folder.url.appending(path: "web.jpg")
        let print = folder.url.appending(path: "print.jpg")

        try PhotoConverter.convert(source, to: web, settings: ExportPreset.webJPEG.settings, context: CIContextForTests.shared)
        try PhotoConverter.convert(source, to: print, settings: ExportPreset.printJPEG.settings, context: CIContextForTests.shared)

        for file in [web, print] {
            let properties = try readImage(file).properties
            let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:20 14:40:57")
            #expect(tiff[kCGImagePropertyTIFFMake] as? String == "SONY")
            #expect(tiff[kCGImagePropertyTIFFModel] as? String == "ILCE-6000")
        }
        #expect(try readImage(web).properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(try readImage(print).properties[kCGImagePropertyGPSDictionary] != nil)
    }

    // `arguments:` runs the same test once per value (like `test.each` in Jest).
    @Test(arguments: ExportPreset.allCases)
    func everyPresetWritesAnOpaqueFileOfItsFormat(preset: ExportPreset) throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let source = try writeSourceJPEG(in: folder, "photo.jpg", width: 600, height: 400)
        let output = folder.url.appending(path: "out.\(preset.settings.format.fileExtension)")

        try PhotoConverter.convert(source, to: output, settings: preset.settings, context: CIContextForTests.shared)

        let written = try readImage(output)
        #expect(written.type == preset.settings.format.type.identifier)
        #expect(written.properties[kCGImagePropertyHasAlpha] as? Bool != true)
        #expect(written.image.width == 600)
        if preset == .tiff {
            let tiff = written.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect((tiff?[kCGImagePropertyTIFFCompression] as? NSNumber)?.intValue == 5) // LZW
        }
    }

    @Test func unreadableFileThrows() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let source = try folder.writeFile("broken.ARW")

        #expect(throws: ConversionError.unreadableImage("broken.ARW")) {
            try PhotoConverter.convert(
                source, to: folder.url.appending(path: "out.jpg"), settings: ExportPreset.webJPEG.settings, context: CIContextForTests.shared
            )
        }
    }
}

/// F6: export of several photos into a chosen folder.
@MainActor
struct PhotoExporterTests {
    @Test func exportsIntoTheChosenFolderWithoutReplacingAnythingOrTouchingTheOriginals() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        try writeSourceJPEG(in: photos, "a.jpg", width: 900, height: 600)
        try writeSourceJPEG(in: photos, "Jour 2/b.jpg", width: 600, height: 900)
        let existing = try destination.writeFile("a.jpg", contents: "already here")
        let before = try photos.snapshot()
        let progressSeen = ProgressLog()

        let summary = try await PhotoExporter(concurrency: 2).export(
            request(photos, ["a.jpg", "Jour 2/b.jpg"], preset: .webJPEG, destination: destination)
        ) { progress in
            progressSeen.completed.append(progress.completed)
        }

        #expect(summary.exportedFiles.map(\.lastPathComponent) == ["a (2).jpg", "b.jpg"])
        #expect(summary.failures.isEmpty)
        #expect(!summary.wasCancelled)
        #expect(progressSeen.completed.last == 2)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "already here")
        #expect(try photos.snapshot() == before)
        #expect(try destination.fileNames() == ["a (2).jpg", "a.jpg", "b.jpg"])
        #expect(try readImage(summary.exportedFiles[1]).image.height == 900) // portrait stays a portrait
    }

    @Test func anUnreadablePhotoOrAVideoDoesNotStopTheExport() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        try writeSourceJPEG(in: photos, "good.jpg", width: 300, height: 200)
        try photos.writeFile("broken.jpg")
        try photos.writeFile("clip.mov")

        let summary = try await PhotoExporter().export(
            request(photos, ["good.jpg", "broken.jpg", "clip.mov"], preset: .heic, destination: destination)
        )

        #expect(summary.exportedFiles.map(\.lastPathComponent) == ["good.heic"])
        #expect(Set(summary.failures.map(\.relativePath)) == ["broken.jpg", "clip.mov"])
        #expect(summary.failures.first { $0.relativePath == "clip.mov" }?.message
            == ExportError.videoNotSupportedYet("clip.mov").errorDescription)
        #expect(try destination.fileNames() == ["good.heic"]) // no temporary file left
    }

    @Test func cancellingKeepsTheFinishedPhotosAndLeavesNoTemporaryFile() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        let paths = (1...8).map { "photo\($0).jpg" }
        for path in paths {
            try writeSourceJPEG(in: photos, path, width: 800, height: 600)
        }
        let box = TaskBox()

        box.task = Task {
            try await PhotoExporter(concurrency: 1).export(request(photos, paths, preset: .printJPEG, destination: destination)) { progress in
                if progress.completed == 1 { box.task?.cancel() }
            }
        }
        let summary = try await #require(box.task).value

        #expect(summary.wasCancelled)
        #expect(summary.exportedFiles.map(\.lastPathComponent) == ["photo1.jpg"])
        #expect(try destination.fileNames() == ["photo1.jpg"])
    }

    @Test func aMissingGalleryFolderIsReported() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { destination.remove() }
        let missing = request(photos, ["a.jpg"], preset: .webJPEG, destination: destination)
        photos.remove()

        await #expect(throws: LibraryError.folderNotFound(photos.url.path)) {
            try await PhotoExporter().export(missing)
        }
    }

    @Test func aFileAppearingDuringTheExportIsNotReplaced() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let temporary = try folder.writeFile(".x.tmp", contents: "new")
        try folder.writeFile("x.jpg", contents: "old")

        let moved = try PhotoExporter.moveWithoutReplacing(temporary, into: folder.url, plannedName: "x.jpg", base: "x", fileExtension: "jpg")

        #expect(moved.lastPathComponent == "x (2).jpg")
        #expect(try String(contentsOf: folder.url.appending(path: "x.jpg"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "new")
    }

    @Test func controllerShowsTheSummaryOnceFinished() async throws {
        let (photos, destination) = try (TestFolder(), TestFolder())
        defer { photos.remove(); destination.remove() }
        try writeSourceJPEG(in: photos, "a.jpg", width: 300, height: 200)
        let controller = ExportController()

        controller.start(request(photos, ["a.jpg"], preset: .webJPEG, destination: destination))
        #expect(controller.isExporting)
        await controller.waitUntilFinished()

        #expect(!controller.isExporting)
        #expect(controller.progress == nil)
        #expect(controller.summary?.exportedFiles.map(\.lastPathComponent) == ["a.jpg"])
        #expect(controller.errorMessage == nil)
    }

    private func request(_ photos: TestFolder, _ paths: [String], preset: ExportPreset, destination: TestFolder) -> ExportRequest {
        ExportRequest(
            galleryId: UUID(),
            galleryName: "Séance",
            folderPath: photos.url.path,
            folderBookmark: (try? FolderBookmark.create(for: photos.url)) ?? Data(),
            items: paths.map { ExportItem(photoId: UUID(), relativePath: $0) },
            preset: preset,
            destination: destination.url
        )
    }
}

/// F6: which photos are exported.
@MainActor
struct ExportScopeTests {
    @Test func defaultsToThePhotosToKeep() throws {
        let container = try makeInMemoryContainer()
        let photos = ["a.ARW", "b.ARW", "c.ARW"].map { makePhoto($0, in: container) }
        photos[0].cullingVerdictRaw = CullingVerdict.keep.rawValue
        photos[1].cullingVerdictRaw = CullingVerdict.reject.rawValue

        #expect(ExportScope.defaultScope(for: photos) == .keep)
        #expect(ExportScope.keep.photos(from: photos, selectedPhotoId: nil).map(\.relativePath) == ["a.ARW"])
        #expect(ExportScope.all.photos(from: photos, selectedPhotoId: nil).count == 3)
        #expect(ExportScope.selection.photos(from: photos, selectedPhotoId: photos[2].id).map(\.relativePath) == ["c.ARW"])
    }

    @Test func exportsEverythingWhenNothingIsMarkedToKeep() throws {
        let container = try makeInMemoryContainer()
        let photos = ["a.ARW", "b.ARW"].map { makePhoto($0, in: container) }

        #expect(ExportScope.defaultScope(for: photos) == .all)
    }

    @Test func recognisesVideosByTheirExtension() {
        #expect(MediaKind(relativePath: "Jour 1/C0001.MP4") == .video)
        #expect(MediaKind(relativePath: "clip.mov") == .video)
        #expect(MediaKind(relativePath: "DSC04297.ARW") == .photo)
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

// MARK: - Helpers

enum CIContextForTests {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}

/// Progress values seen by a test. A class, because a `@Sendable` closure cannot change a local `var`.
@MainActor
private final class ProgressLog {
    var completed: [Int] = []
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)! // built into the system, never nil

/// Lets a task's own progress callback cancel it.
@MainActor
private final class TaskBox {
    var task: Task<ExportSummary, Error>?
}

private extension TestFolder {
    /// Visible files of the folder, sorted (a hidden temporary file would also be listed).
    func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

/// A real JPEG: blue, or red on its left half; optionally with an orientation, a date, a camera and a GPS position.
@discardableResult
private func writeSourceJPEG(
    in folder: TestFolder,
    _ relativePath: String,
    width: Int,
    height: Int,
    orientation: Int? = nil,
    redLeftHalf: Bool = false,
    withMetadata: Bool = false
) throws -> URL {
    let file = folder.url.appending(path: relativePath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if redLeftHalf {
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    if withMetadata {
        properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:09:20 14:40:57"]
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-6000"]
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: 48.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.2, kCGImagePropertyGPSLongitudeRef: "E",
        ]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return file
}

private func readImage(_ url: URL) throws -> (image: CGImage, type: String, properties: [CFString: Any]) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let type = try #require(CGImageSourceGetType(source) as String?)
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    return (image, type, properties)
}

/// Colour of one pixel, `y` counted from the top.
private func pixel(of image: CGImage, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
    let context = try #require(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    // The bitmap's first row in memory is the top of the image.
    let offset = y * image.width * 4 + x * 4
    return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
}
