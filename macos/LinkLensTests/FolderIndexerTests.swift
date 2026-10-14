import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// F2: indexing an existing folder in place.
struct FolderIndexerTests {
    @Test func indexesEveryPhotoInBatchesWithoutTouchingTheFolder() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC2.jpg", width: 80, height: 60, exifDate: "2026:09:20 14:40:59")
        try folder.writeJPEG("DSC10.jpg", exifDate: "2026:09:20 14:41:00")
        try folder.writeJPEG("DSC1.jpg", exifDate: "2026:09:20 14:40:57")
        try folder.writeJPEG("Jour 2/IMG_1.jpeg")
        try folder.writeFile("broken.ARW")
        try folder.writeFile("notes.txt")
        let before = try folder.snapshot()

        let container = try makeInMemoryContainer()
        let indexer = FolderIndexer(store: LibraryStore(modelContainer: container), batchSize: 2)
        let recorder = ProgressRecorder()
        let result = try await indexer.indexFolder(at: folder.url) { progress in
            recorder.values.append(progress)
        }

        // The folder is exactly as before: same files, same contents, same dates.
        #expect(try folder.snapshot() == before)

        let context = ModelContext(container)
        let gallery = try #require(try context.fetch(FetchDescriptor<Gallery>()).first)
        #expect(result == .indexed(galleryId: gallery.id, photoCount: 5))
        #expect(gallery.name == folder.url.lastPathComponent)
        #expect(gallery.folderPath == FolderBookmark.canonicalPath(of: folder.url))
        #expect(gallery.photoCount == 5)
        #expect(gallery.indexedAt != nil)
        #expect(!gallery.folderBookmark.isEmpty)

        let photos = try context.fetch(FetchDescriptor<Photo>())
        #expect(photos.map(\.relativePath).sorted() == ["DSC1.jpg", "DSC10.jpg", "DSC2.jpg", "Jour 2/IMG_1.jpeg", "broken.ARW"])
        #expect(photos.allSatisfy { $0.gallery?.id == gallery.id })
        let dsc2 = try #require(photos.first { $0.relativePath == "DSC2.jpg" })
        #expect(dsc2.pixelWidth == 80 && dsc2.pixelHeight == 60)
        #expect(dsc2.captureDate == PhotoMetadataReader.parseExifDate("2026:09:20 14:40:59", subseconds: nil))
        let broken = try #require(photos.first { $0.relativePath == "broken.ARW" })
        #expect(broken.pixelWidth == 0 && broken.captureDate == nil)

        // 5 photos in batches of 2: start, then 2, 4 and 5.
        let progress = await recorder.values
        #expect(progress.map(\.completed) == [0, 2, 4, 5])
        #expect(progress.allSatisfy { $0.total == 5 && $0.galleryId == gallery.id })
    }

    @Test func sameFolderTwiceReturnsTheExistingGallery() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("a.jpg")
        let container = try makeInMemoryContainer()
        let indexer = FolderIndexer(store: LibraryStore(modelContainer: container))

        let first = try await indexer.indexFolder(at: folder.url)
        let second = try await indexer.indexFolder(at: folder.url)

        guard case .indexed(let galleryId, _) = first else {
            Issue.record("first indexing should create a gallery")
            return
        }
        #expect(second == .alreadyIndexed(galleryId: galleryId))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Gallery>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Photo>()) == 1)
    }

    @Test func folderWithoutPhotosCreatesNoGallery() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeFile("notes.txt")
        let container = try makeInMemoryContainer()
        let indexer = FolderIndexer(store: LibraryStore(modelContainer: container))

        await #expect(throws: LibraryError.noPhotos(folder.url.lastPathComponent)) {
            try await indexer.indexFolder(at: folder.url)
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Gallery>()) == 0)
    }

    @MainActor
    @Test func cancellingRemovesThePartialGallery() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        for index in 1...6 {
            try folder.writeJPEG("DSC\(index).jpg")
        }
        let container = try makeInMemoryContainer()
        let indexer = FolderIndexer(store: LibraryStore(modelContainer: container), batchSize: 2)

        let box = TaskBox()
        box.task = Task {
            try await indexer.indexFolder(at: folder.url) { progress in
                if progress.completed == 2 { box.task?.cancel() }
            }
        }

        await #expect(throws: CancellationError.self) {
            try await box.task?.value
        }
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Gallery>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Photo>()) == 0)
    }

    @Test func unfinishedGalleriesAreRemovedAtLaunch() async throws {
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let unfinished = try await store.createGallery(name: "Coupée", folderPath: "/a", folderBookmark: Data())
        let finished = try await store.createGallery(name: "Finie", folderPath: "/b", folderBookmark: Data())
        try await store.finishIndexing(galleryId: finished)

        #expect(try await store.deleteUnfinishedGalleries() == 1)

        let remaining = try ModelContext(container).fetch(FetchDescriptor<Gallery>()).map(\.id)
        #expect(remaining == [finished])
        #expect(!remaining.contains(unfinished))
    }
}

@MainActor
private final class ProgressRecorder {
    var values: [IndexingProgress] = []
}

@MainActor
private final class TaskBox {
    var task: Task<IndexingResult, Error>?
}
