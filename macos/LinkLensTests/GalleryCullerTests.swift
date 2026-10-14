import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import LinkLens

/// F3: sorting a gallery indexed by F2, from the bookmark to the verdicts stored on each photo.
struct GalleryCullerTests {
    @Test func sortsEveryPhotoWithAReasonWithoutTouchingTheFolder() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try writeCheckerboardJPEG(folder.url.appending(path: "sharp.jpg"))
        try folder.writeJPEG("flat.jpg", width: 1200, height: 800)
        try folder.writeFile("broken.ARW")
        let before = try folder.snapshot()

        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await indexedGallery(folder, store: store)

        let recorder = CullingProgressRecorder()
        let summary = try await GalleryCuller(store: store, batchSize: 2).cullGallery(id: galleryId) { progress in
            recorder.values.append(progress)
        }

        // The AI only proposes: the folder is exactly as before.
        #expect(try folder.snapshot() == before)
        #expect(summary.keep + summary.review + summary.reject == 3)
        #expect(summary.failed == 1)
        #expect(await recorder.values.first?.completed == 0)
        #expect(await recorder.values.last == CullingProgress(galleryId: galleryId, completed: 3, total: 3))

        let context = ModelContext(container)
        let gallery = try #require(try context.fetch(FetchDescriptor<Gallery>()).first)
        #expect(gallery.culledAt != nil)
        let photos = try context.fetch(FetchDescriptor<Photo>())
        for photo in photos {
            #expect(photo.analyzedAt != nil)
            #expect(photo.cullingVerdict != nil)
            #expect(!photo.cullingReasons.isEmpty, "every verdict comes with a reason")
            #expect(photo.cullingVerdict == photo.cullingReasons.first?.verdict)
        }
        let broken = try #require(photos.first { $0.relativePath == "broken.ARW" })
        #expect(broken.cullingVerdict == .review)
        #expect(broken.cullingReasons.map(\.kind) == [.analysisFailed])
        let flat = try #require(photos.first { $0.relativePath == "flat.jpg" })
        #expect(flat.cullingVerdict == .reject)
        #expect(flat.cullingReasons.first?.kind == .blurry)
    }

    @MainActor
    @Test func cancellingKeepsThePreviousVerdicts() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("a.jpg", width: 1200, height: 800)
        try folder.writeJPEG("b.jpg", width: 1200, height: 800)
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await indexedGallery(folder, store: store)
        let culler = GalleryCuller(store: store)
        _ = try await culler.cullGallery(id: galleryId)
        let firstRun = try ModelContext(container).fetch(FetchDescriptor<Photo>()).map(\.analyzedAt)

        let box = CullingTaskBox()
        box.task = Task {
            try await culler.cullGallery(id: galleryId) { progress in
                if progress.completed == 0 { box.task?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) {
            try await box.task?.value
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Photo>()).map(\.analyzedAt) == firstRun)
    }

    @Test func unreachableFolderIsReported() async throws {
        let folder = try TestFolder()
        try folder.writeJPEG("a.jpg")
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await indexedGallery(folder, store: store)
        folder.remove()

        await #expect(throws: (any Error).self) {
            try await GalleryCuller(store: store).cullGallery(id: galleryId)
        }
        let gallery = try #require(try ModelContext(container).fetch(FetchDescriptor<Gallery>()).first)
        #expect(gallery.culledAt == nil)
    }

    @Test func galleriesNeverSortedAreFoundAtLaunch() async throws {
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let sorted = try await store.createGallery(name: "Triée", folderPath: "/a", folderBookmark: Data())
        let pending = try await store.createGallery(name: "À trier", folderPath: "/b", folderBookmark: Data())
        _ = try await store.createGallery(name: "Indexation coupée", folderPath: "/c", folderBookmark: Data())
        try await store.finishIndexing(galleryId: sorted)
        try await store.finishIndexing(galleryId: pending)
        try await store.finishCulling(galleryId: sorted)

        #expect(try await store.galleriesToCull() == [pending])
    }

    // MARK: - Helpers

    private func indexedGallery(_ folder: TestFolder, store: LibraryStore) async throws -> UUID {
        let result = try await FolderIndexer(store: store).indexFolder(at: folder.url)
        guard case .indexed(let galleryId, _) = result else {
            throw LibraryError.galleryNotFound
        }
        return galleryId
    }

    /// A sharp black-and-white checkerboard, big enough for Vision.
    private func writeCheckerboardJPEG(_ url: URL, width: Int = 1200, height: Int = 800) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 0, to: height, by: 20) {
            for x in stride(from: 0, to: width, by: 20) where (x / 20 + y / 20) % 2 == 0 {
                context.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}

@MainActor
private final class CullingProgressRecorder {
    var values: [CullingProgress] = []
}

@MainActor
private final class CullingTaskBox {
    var task: Task<CullingSummary, Error>?
}
