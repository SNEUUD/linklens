import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// What the gallery view derives from its photos in one pass (`GalleryPhotos`).
@MainActor
struct GalleryPhotosTests {
    /// Stored photos (the counts read `Photo.verdict`, the lookups need real models).
    private func makePhotos(_ count: Int, in container: ModelContainer, configure: (Int, Photo) -> Void) throws -> [Photo] {
        let gallery = Gallery(name: "G", folderPath: "/g", folderBookmark: Data())
        container.mainContext.insert(gallery)
        let photos = (0..<count).map { index in
            let photo = Photo(draft: PhotoDraft(
                file: PhotoFile(url: URL(filePath: "/g/DSC\(index).ARW"), relativePath: "DSC\(index).ARW", fileSize: 1),
                metadata: PhotoMetadata(captureDate: Date(timeIntervalSince1970: Double(index)), pixelWidth: 6000, pixelHeight: 4000),
                importedAt: .now
            ))
            container.mainContext.insert(photo)
            photo.gallery = gallery
            configure(index, photo)
            return photo
        }
        try container.mainContext.save()
        return photos
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Gallery.self, Photo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func countsLookupsAndPendingPhotos() throws {
        let container = try makeContainer()
        let photos = try makePhotos(6, in: container) { index, photo in
            photo.cullingVerdictRaw = ["keep", "review", "reject", "reject", "reject", "keep"][index]
            if index == 3 { photo.pendingTrashAt = .now }
            if index == 1 { photo.userVerdictRaw = "reject" }
        }

        let facts = GalleryPhotos(photos)

        #expect(facts.counts == VerdictFilterCounts(all: 6, keep: 2, review: 0, reject: 4), "the user's choice counts over the AI's")
        #expect(facts.photoCount == 6)
        #expect(facts.pending.map(\.id) == [photos[3].id])
        #expect(facts.rejectedNotPendingCount == 3, "rejected photos already waiting for the trash are not counted again")
        #expect(facts.photo(id: photos[4].id) === photos[4])
        #expect(facts.photo(id: nil) == nil)
        #expect(facts.photo(id: UUID()) == nil)
        #expect(facts.burstInputs.map(\.id) == photos.map(\.id), "same order as the photos")
    }

    @Test func burstMembersKeepTheDisplayOrder() throws {
        let container = try makeContainer()
        let photos = try makePhotos(7, in: container) { index, photo in
            photo.burstNumber = [1, 2, 1, nil, 1, 2, nil][index]
        }

        let facts = GalleryPhotos(photos)

        #expect(facts.burstMembers(of: 1).map(\.id) == [photos[0], photos[2], photos[4]].map(\.id))
        #expect(facts.burstMembers(of: 3).isEmpty)
    }

    @Test func videosAreLeftOutOfThePhotoCount() throws {
        let container = try makeContainer()
        let photos = try makePhotos(3, in: container) { index, photo in
            if index == 2 { photo.mediaKindRaw = MediaKind.video.rawValue }
        }

        #expect(GalleryPhotos(photos).photoCount == 2)
    }

    /// A big gallery: one pass and the lookups after a deletion stay well under a frame budget per click.
    @Test func aBigGalleryIsReadInOnePass() throws {
        let container = try makeContainer()
        _ = try makePhotos(4_120, in: container) { index, photo in
            photo.cullingVerdictRaw = ["keep", "review", "reject"][index % 3]
            photo.burstNumber = index % 5 == 0 ? nil : index / 5
        }
        let context = ModelContext(container)
        let fetched = try context.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.captureDate)]))
        let clock = ContinuousClock()

        let start = clock.now
        let facts = GalleryPhotos(fetched)
        let onePass = start.duration(to: clock.now)
        let lookupStart = clock.now
        for photo in fetched { _ = facts.photo(id: photo.id) }
        let lookups = lookupStart.duration(to: clock.now)

        #expect(facts.counts.all == 4_120)
        #expect(onePass < .milliseconds(500), "one pass over 4 120 photos: \(onePass)")
        #expect(lookups < .milliseconds(100), "4 120 lookups by id: \(lookups)")
    }
}
