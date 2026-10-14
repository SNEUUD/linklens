import Foundation
import SwiftData

/// Background actor owning its own SwiftData context: every bulk write goes through it.
///
/// An `actor` is an object whose methods run one at a time, off the main thread
/// (think of a small server you `await`). `@ModelActor` generates `init(modelContainer:)`
/// and a private `modelContext`. The interface still reads the same data through `@Query`.
@ModelActor
actor LibraryStore {
    /// Id of the fully indexed gallery that already points to this folder, if any.
    func galleryId(forFolderPath folderPath: String) throws -> UUID? {
        var descriptor = FetchDescriptor<Gallery>(
            predicate: #Predicate { $0.folderPath == folderPath && $0.indexedAt != nil }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.id
    }

    func createGallery(name: String, folderPath: String, folderBookmark: Data) throws -> UUID {
        let gallery = Gallery(name: name, folderPath: folderPath, folderBookmark: folderBookmark)
        modelContext.insert(gallery)
        try modelContext.save()
        return gallery.id
    }

    /// Inserts one batch and saves it (one transaction per batch).
    func insert(_ drafts: [PhotoDraft], galleryId: UUID) throws {
        let gallery = try fetchGallery(id: galleryId)
        for draft in drafts {
            let photo = Photo(draft: draft)
            modelContext.insert(photo)
            photo.gallery = gallery
        }
        gallery.photoCount += drafts.count
        try modelContext.save()
    }

    func finishIndexing(galleryId: UUID) throws {
        try fetchGallery(id: galleryId).indexedAt = Date()
        try modelContext.save()
    }

    /// Removes the gallery and its photos from the catalogue. The files on disk are not touched.
    func deleteGallery(id: UUID) throws {
        modelContext.delete(try fetchGallery(id: id))
        try modelContext.save()
    }

    /// Galleries left half-indexed (app quit during indexing) are removed at launch.
    func deleteUnfinishedGalleries() throws -> Int {
        let unfinished = try modelContext.fetch(FetchDescriptor<Gallery>(predicate: #Predicate { $0.indexedAt == nil }))
        for gallery in unfinished {
            modelContext.delete(gallery)
        }
        try modelContext.save()
        return unfinished.count
    }

    // MARK: - Culling (F3)

    /// What the analysis needs: the folder bookmark and the photos (as `Sendable` copies).
    func cullingContents(galleryId: UUID) throws -> GalleryContents {
        let gallery = try fetchGallery(id: galleryId)
        let photos = try modelContext.fetch(FetchDescriptor<Photo>(predicate: #Predicate { $0.gallery?.id == galleryId }))
        return GalleryContents(
            name: gallery.name,
            folderPath: gallery.folderPath,
            folderBookmark: gallery.folderBookmark,
            photos: photos.map { PhotoReference(id: $0.id, relativePath: $0.relativePath, captureDate: $0.captureDate) }
        )
    }

    /// Stores one batch of verdicts and saves it (one transaction per batch).
    func saveCulling(_ results: [CullingResult], analyzedAt: Date) throws {
        let ids = results.map(\.photoId)
        let photos = try modelContext.fetch(FetchDescriptor<Photo>(predicate: #Predicate { ids.contains($0.id) }))
        let photosById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        for result in results {
            try photosById[result.photoId]?.apply(result, analyzedAt: analyzedAt)
        }
        try modelContext.save()
    }

    func finishCulling(galleryId: UUID) throws {
        try fetchGallery(id: galleryId).culledAt = Date()
        try modelContext.save()
    }

    /// Indexed galleries that were never sorted (e.g. indexed before F3, or sorting cancelled), oldest first.
    func galleriesToCull() throws -> [UUID] {
        let descriptor = FetchDescriptor<Gallery>(
            predicate: #Predicate { $0.indexedAt != nil && $0.culledAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map(\.id)
    }

    private func fetchGallery(id: UUID) throws -> Gallery {
        var descriptor = FetchDescriptor<Gallery>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let gallery = try modelContext.fetch(descriptor).first else {
            throw LibraryError.galleryNotFound
        }
        return gallery
    }
}

/// `Sendable` snapshot of a gallery, handed from `LibraryStore` to the analysis.
struct GalleryContents: Sendable {
    var name: String
    var folderPath: String
    var folderBookmark: Data
    var photos: [PhotoReference]
}
