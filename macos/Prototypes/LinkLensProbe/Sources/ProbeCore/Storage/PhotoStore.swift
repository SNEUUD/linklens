import Foundation
import SwiftData

/// Background actor owning its own SwiftData context.
/// `@ModelActor` generates `init(modelContainer:)` and a private `modelContext`:
/// every database access goes through this actor, never through the MainActor.
@ModelActor
actor PhotoStore {
    func createGallery(name: String) throws -> UUID {
        let gallery = Gallery(name: name)
        modelContext.insert(gallery)
        try modelContext.save()
        return gallery.id
    }

    /// Inserts one batch and saves it (one transaction per batch).
    func insert(_ drafts: [PhotoDraft], galleryId: UUID) throws {
        var descriptor = FetchDescriptor<Gallery>(predicate: #Predicate { $0.id == galleryId })
        descriptor.fetchLimit = 1
        guard let gallery = try modelContext.fetch(descriptor).first else {
            throw ProbeError.storeFailure("galerie introuvable")
        }
        for draft in drafts {
            let photo = Photo(draft: draft)
            modelContext.insert(photo)
            photo.gallery = gallery
        }
        try modelContext.save()
    }

    /// "The N best non-rejected photos of a gallery", sorted by aesthetic score.
    func bestPhotos(galleryId: UUID, limit: Int) throws -> [PhotoSummary] {
        let rejected = Verdict.reject.rawValue
        var descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { photo in
                photo.gallery?.id == galleryId && photo.verdictRaw != rejected
            },
            sortBy: [SortDescriptor(\.aestheticScore, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            PhotoSummary(relativePath: $0.relativePath, aestheticScore: $0.aestheticScore, verdict: $0.verdictRaw)
        }
    }

    func photoCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Photo>())
    }
}
