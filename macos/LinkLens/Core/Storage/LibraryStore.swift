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

    func createGallery(name: String, folderPath: String, folderBookmark: Data, volume: VolumeIdentity? = nil) throws -> UUID {
        let gallery = Gallery(name: name, folderPath: folderPath, folderBookmark: folderBookmark)
        gallery.volumeName = volume?.name
        gallery.volumeUUID = volume?.uuid
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
        gallery.videoCount += drafts.filter { $0.mediaKind == .video }.count
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
    /// Videos are left out: the AI sorting only judges photos.
    func cullingContents(galleryId: UUID) throws -> GalleryContents {
        let gallery = try fetchGallery(id: galleryId)
        let photos = try modelContext.fetch(FetchDescriptor<Photo>(predicate: #Predicate { $0.gallery?.id == galleryId }))
            .filter { $0.mediaKind == .photo }
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

    // MARK: - Duplicates (F5)

    /// Every file of the fully indexed galleries, with the location of each gallery.
    func duplicateCatalogue() throws -> (galleries: [GalleryLocation], files: [DuplicateCopy]) {
        let galleries = try modelContext.fetch(FetchDescriptor<Gallery>(predicate: #Predicate { $0.indexedAt != nil }))
        var files: [DuplicateCopy] = []
        for gallery in galleries {
            for photo in gallery.photos {
                files.append(DuplicateCopy(
                    photoId: photo.id, galleryId: gallery.id, galleryName: gallery.name,
                    galleryCreatedAt: gallery.createdAt, relativePath: photo.relativePath,
                    fileSize: photo.fileSize, sha256: photo.sha256, verdict: photo.verdict
                ))
            }
        }
        return (galleries.map(\.location), files)
    }

    /// Location of every gallery (without their photos), with the bookmarks as saved right now.
    func galleryLocations() throws -> [GalleryLocation] {
        try modelContext.fetch(FetchDescriptor<Gallery>()).map(\.location)
    }

    /// Stores one batch of computed fingerprints (photo id → SHA-256).
    func saveFingerprints(_ fingerprints: [UUID: String]) throws {
        let ids = Array(fingerprints.keys)
        for photo in try modelContext.fetch(FetchDescriptor<Photo>(predicate: #Predicate { ids.contains($0.id) })) {
            photo.sha256 = fingerprints[photo.id]
        }
        try modelContext.save()
    }

    /// After a card import (F1): the fingerprints already checked during the copy, by path in the
    /// gallery, and the read-write bookmark of the new session folder.
    func saveImportedFingerprints(_ fingerprints: [String: String], writeBookmark: Data?, galleryId: UUID) throws {
        let gallery = try fetchGallery(id: galleryId)
        gallery.writeBookmark = writeBookmark
        for photo in gallery.photos {
            if let sha256 = fingerprints[photo.relativePath] {
                photo.sha256 = sha256
            }
        }
        try modelContext.save()
    }

    func setWriteBookmark(_ bookmark: Data, galleryId: UUID) throws {
        try fetchGallery(id: galleryId).writeBookmark = bookmark
        try modelContext.save()
    }

    // MARK: - Availability (F9)

    /// Saves what an availability check learnt: the disk's name, and a fresh bookmark when the folder
    /// was moved or renamed. Checks with nothing new are skipped.
    func saveAvailabilityChecks(_ checks: [AvailabilityCheck]) throws {
        let changed = checks.filter { $0.volume != nil || $0.refreshedBookmark != nil }
        guard !changed.isEmpty else { return }
        let ids = changed.map(\.galleryId)
        let galleries = try modelContext.fetch(FetchDescriptor<Gallery>(predicate: #Predicate { ids.contains($0.id) }))
        let galleriesById = Dictionary(uniqueKeysWithValues: galleries.map { ($0.id, $0) })
        for check in changed {
            guard let gallery = galleriesById[check.galleryId] else { continue }
            if let volume = check.volume {
                gallery.volumeName = volume.name
                gallery.volumeUUID = volume.uuid
            }
            if let bookmark = check.refreshedBookmark, let path = check.refreshedFolderPath {
                gallery.folderBookmark = bookmark
                gallery.folderPath = path
            }
        }
        try modelContext.save()
    }

    /// Removes photos whose file went to the trash. Returns what is needed to put them back.
    func removePhotos(ids: [UUID]) throws -> [PhotoSnapshot] {
        let photos = try modelContext.fetch(FetchDescriptor<Photo>(predicate: #Predicate { ids.contains($0.id) }))
        let snapshots = photos.map(\.snapshot)
        for photo in photos {
            if let gallery = photo.gallery {
                gallery.photoCount -= 1
                if photo.mediaKind == .video { gallery.videoCount -= 1 }
            }
            modelContext.delete(photo)
        }
        try modelContext.save()
        return snapshots
    }

    /// "Annuler": puts removed photos back in their gallery, unchanged. Photos already there are skipped.
    func restorePhotos(_ snapshots: [PhotoSnapshot], galleryId: UUID) throws {
        let gallery = try fetchGallery(id: galleryId)
        let ids = snapshots.map(\.id)
        let existing = Set(try modelContext.fetch(FetchDescriptor<Photo>(predicate: #Predicate { ids.contains($0.id) })).map(\.id))
        for snapshot in snapshots where !existing.contains(snapshot.id) {
            let photo = Photo(snapshot: snapshot)
            modelContext.insert(photo)
            photo.gallery = gallery
            gallery.photoCount += 1
            if photo.mediaKind == .video { gallery.videoCount += 1 }
        }
        try modelContext.save()
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

extension Gallery {
    var location: GalleryLocation {
        GalleryLocation(
            id: id, name: name, folderPath: folderPath, createdAt: createdAt,
            folderBookmark: folderBookmark, writeBookmark: writeBookmark,
            volumeName: volumeName, volumeUUID: volumeUUID
        )
    }
}

/// `Sendable` snapshot of a gallery, handed from `LibraryStore` to the analysis.
struct GalleryContents: Sendable {
    var name: String
    var folderPath: String
    var folderBookmark: Data
    var photos: [PhotoReference]
}
