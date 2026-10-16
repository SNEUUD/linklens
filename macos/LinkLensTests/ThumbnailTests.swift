import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LinkLens

/// Thumbnails of the grid: generation from the photo, disk cache keyed by photo id, background loader.
struct ThumbnailGeneratorTests {
    @Test func scalesTheLongSideDownToTheLimit() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let file = try folder.writeJPEG("big.jpg", width: 1800, height: 1200)

        let thumbnail = try ThumbnailGenerator.makeThumbnail(from: file)

        #expect(thumbnail.width == ThumbnailGenerator.maxPixelSize)
        #expect(thumbnail.height == 341)
    }

    @Test func neverEnlargesASmallPhoto() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let file = try folder.writeJPEG("small.jpg", width: 64, height: 48)

        let thumbnail = try ThumbnailGenerator.makeThumbnail(from: file)

        #expect(thumbnail.width == 64)
        #expect(thumbnail.height == 48)
    }

    @Test func ignoresATinyEmbeddedPreview() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        // A JPEG with the usual 160 px EXIF thumbnail: too small, the image itself must be decoded.
        let file = folder.url.appending(path: "with-exif-thumbnail.jpg")
        try writeJPEG(to: file, width: 1800, height: 1200, embedThumbnail: true)

        let thumbnail = try ThumbnailGenerator.makeThumbnail(from: file)

        #expect(thumbnail.width == ThumbnailGenerator.maxPixelSize)
    }

    @Test func appliesTheExifRotation() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        // Stored landscape, orientation 6 = "rotate 90° to display": the photo is a portrait.
        let file = folder.url.appending(path: "portrait.jpg")
        try writeJPEG(to: file, width: 900, height: 600, orientation: 6)

        let thumbnail = try ThumbnailGenerator.makeThumbnail(from: file)

        #expect(thumbnail.width == 341)
        #expect(thumbnail.height == ThumbnailGenerator.maxPixelSize)
    }

    @Test func unreadableFileThrows() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let file = try folder.writeFile("broken.ARW")

        #expect(throws: AnalysisError.unreadableImage("broken.ARW")) {
            try ThumbnailGenerator.makeThumbnail(from: file)
        }
    }
}

struct ThumbnailCacheTests {
    @Test func storesAndReadsBackByPhotoId() throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        let cache = ThumbnailCache(directory: cacheFolder.url.appending(path: "Thumbnails"))
        let photoId = UUID()
        let thumbnail = try ThumbnailGenerator.makeThumbnail(from: photos.writeJPEG("a.jpg", width: 900, height: 600))

        #expect(!cache.contains(photoId))
        #expect(cache.image(for: photoId) == nil)
        try cache.store(thumbnail, for: photoId)

        #expect(cache.contains(photoId))
        #expect(cache.fileURL(for: photoId).lastPathComponent == "\(photoId.uuidString).jpg")
        let read = try #require(cache.image(for: photoId))
        #expect(read.width == thumbnail.width)
        #expect(read.height == thumbnail.height)
    }

    @Test func survivesTheSourceFileDisappearing() throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        let cache = ThumbnailCache(directory: cacheFolder.url)
        let file = try photos.writeJPEG("a.jpg", width: 900, height: 600)
        let photoId = UUID()
        try cache.store(try ThumbnailGenerator.makeThumbnail(from: file), for: photoId)

        // Folder renamed or disk unplugged (F9): the key is the photo, not its path.
        try FileManager.default.removeItem(at: file)

        #expect(cache.image(for: photoId) != nil)
    }

    @Test func listsTheMissingIdsInOrder() throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        let cache = ThumbnailCache(directory: cacheFolder.url.appending(path: "not-created-yet"))
        let ids = (0..<4).map { _ in UUID() }

        #expect(cache.missing(among: ids) == ids)

        let thumbnail = try ThumbnailGenerator.makeThumbnail(from: photos.writeJPEG("a.jpg"))
        try cache.store(thumbnail, for: ids[1])
        try cache.store(thumbnail, for: ids[3])

        #expect(cache.missing(among: ids) == [ids[0], ids[2]])
    }
}

@MainActor
struct ThumbnailLoaderTests {
    @Test func generatesCachesAndNeverTouchesTheFolder() async throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        try photos.writeJPEG("a.jpg", width: 900, height: 600)
        try photos.writeJPEG("Jour 2/b.jpg", width: 600, height: 900)
        let before = try photos.snapshot()
        let cache = ThumbnailCache(directory: cacheFolder.url)
        let loader = ThumbnailLoader(cache: cache)
        loader.open(folderBookmark: try FolderBookmark.create(for: photos.url))
        defer { loader.stop() }

        let a = ThumbnailRequest(photoId: UUID(), relativePath: "a.jpg")
        let b = ThumbnailRequest(photoId: UUID(), relativePath: "Jour 2/b.jpg")
        let imageA = try #require(await loader.thumbnail(for: a))
        let imageB = try #require(await loader.thumbnail(for: b))

        #expect(imageA.width == ThumbnailGenerator.maxPixelSize)
        #expect(imageB.height == ThumbnailGenerator.maxPixelSize)
        // The disk cache is what must hold. The memory one (`cachedThumbnail`) is not checked: macOS may
        // empty an `NSCache` at any time under memory pressure, which made this test fail now and then.
        #expect(cache.contains(a.photoId) && cache.contains(b.photoId))
        // Only the cache was written to: the photo folder is exactly as before.
        #expect(try photos.snapshot() == before)
    }

    @Test func prefetchFillsTheCacheInTheBackground() async throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        let requests = try (0..<12).map { index in
            try photos.writeJPEG("photo-\(index).jpg", width: 600, height: 400)
            return ThumbnailRequest(photoId: UUID(), relativePath: "photo-\(index).jpg")
        }
        let cache = ThumbnailCache(directory: cacheFolder.url)
        let loader = ThumbnailLoader(cache: cache, maxConcurrentGenerations: 3)
        loader.open(folderBookmark: try FolderBookmark.create(for: photos.url))
        defer { loader.stop() }

        await loader.prefetch(requests)
        await loader.waitUntilIdle()

        #expect(cache.missing(among: requests.map(\.photoId)).isEmpty)
    }

    @Test func servesTheCacheWhenTheFolderIsUnreachable() async throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        let cache = ThumbnailCache(directory: cacheFolder.url)
        let cached = ThumbnailRequest(photoId: UUID(), relativePath: "a.jpg")
        try cache.store(try ThumbnailGenerator.makeThumbnail(from: photos.writeJPEG("a.jpg")), for: cached.photoId)
        let notCached = ThumbnailRequest(photoId: UUID(), relativePath: "b.jpg")

        // A bookmark that cannot be resolved, like a disk that is unplugged (F9).
        let loader = ThumbnailLoader(cache: cache)
        loader.open(folderBookmark: Data("pas un bookmark".utf8))
        defer { loader.stop() }

        #expect(loader.folder == nil)
        #expect(await loader.thumbnail(for: cached) != nil)
        #expect(await loader.thumbnail(for: notCached) == nil)
        #expect(await loader.preview(for: cached) == nil)
    }

    @Test func unreadablePhotoGivesNoImage() async throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        try photos.writeFile("broken.ARW")
        let cache = ThumbnailCache(directory: cacheFolder.url)
        let loader = ThumbnailLoader(cache: cache)
        loader.open(folderBookmark: try FolderBookmark.create(for: photos.url))
        defer { loader.stop() }
        let request = ThumbnailRequest(photoId: UUID(), relativePath: "broken.ARW")

        #expect(await loader.thumbnail(for: request) == nil)
        #expect(await loader.thumbnail(for: request) == nil, "not retried, and no hang")
        #expect(!cache.contains(request.photoId))
    }

    @Test func previewIsTheLargeImage() async throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        try photos.writeJPEG("a.jpg", width: 1800, height: 1200)
        let loader = ThumbnailLoader(cache: ThumbnailCache(directory: cacheFolder.url))
        loader.open(folderBookmark: try FolderBookmark.create(for: photos.url))
        defer { loader.stop() }

        let preview = try #require(await loader.preview(for: ThumbnailRequest(photoId: UUID(), relativePath: "a.jpg")))

        #expect(preview.width == 1800)
    }

    @Test func stopWakesUpWaitersWithNoImage() async throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        let loader = ThumbnailLoader(cache: ThumbnailCache(directory: cacheFolder.url))
        loader.open(folderBookmark: try FolderBookmark.create(for: photos.url))
        loader.stop()

        #expect(await loader.thumbnail(for: ThumbnailRequest(photoId: UUID(), relativePath: "a.jpg")) == nil)
        await loader.waitUntilIdle()
    }
}

struct GridLayoutTests {
    @Test func fitsAsManyColumnsAsTheWidthAllows() {
        #expect(GridLayout.columnCount(forWidth: 100) == 1)
        #expect(GridLayout.columnCount(forWidth: 420) == 2)
        #expect(GridLayout.columnCount(forWidth: 820) == 4)
    }

    @Test func arrowsMoveAndStopAtTheEdges() {
        // 10 photos on 4 columns:  0 1 2 3 / 4 5 6 7 / 8 9
        func move(_ direction: GridLayout.Direction, from index: Int?) -> Int? {
            GridLayout.index(moving: direction, from: index, count: 10, columns: 4)
        }
        #expect(move(.right, from: nil) == 0)
        #expect(move(.left, from: 0) == 0)
        #expect(move(.right, from: 3) == 4)
        #expect(move(.right, from: 9) == 9)
        #expect(move(.up, from: 2) == 2)
        #expect(move(.up, from: 6) == 2)
        #expect(move(.down, from: 1) == 5)
        #expect(move(.down, from: 6) == 9, "row below is shorter: last photo")
        #expect(move(.down, from: 8) == 8)
        #expect(GridLayout.index(moving: .down, from: nil, count: 0, columns: 4) == nil)
    }
}

/// A landscape JPEG, optionally with an EXIF orientation or the small embedded EXIF thumbnail.
private func writeJPEG(to url: URL, width: Int, height: Int, orientation: Int? = nil, embedThumbnail: Bool = false) throws {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    if embedThumbnail {
        properties[kCGImageDestinationEmbedThumbnail] = true
        properties[kCGImageDestinationImageMaxPixelSize] = width
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
}
