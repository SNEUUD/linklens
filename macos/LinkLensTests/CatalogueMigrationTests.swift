import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// Batch 3 adds optional fields to `Photo`. A catalogue written by the previous version must open with
/// nothing lost: SwiftData adds the new columns by itself (lightweight migration), empty.
struct CatalogueMigrationTests {
    @Test func aCatalogueFromBeforeTheInspectorOpensWithoutLoss() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LinkLensMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Catalogue.store")
        let galleryId = UUID(), keptId = UUID(), videoId = UUID()
        let analyzedAt = Date(timeIntervalSince1970: 1_789_908_177)
        let reasons = try JSONEncoder().encode([CullingReason(kind: .bestOfBurst, verdict: .keep)])

        // 1. The previous version writes its catalogue, then closes it.
        try {
            let old = try ModelContainer(
                for: Schema([CatalogueV1.Gallery.self, CatalogueV1.Photo.self]),
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(old)
            let gallery = CatalogueV1.Gallery(id: galleryId, name: "Séance du 20 sept.", folderPath: "/Users/chris/Downloads/photos")
            context.insert(gallery)
            let kept = CatalogueV1.Photo(id: keptId, relativePath: "DSC04311.ARW")
            kept.cullingVerdictRaw = "keep"
            kept.cullingReasonsData = reasons
            kept.analyzedAt = analyzedAt
            kept.sharpness = 158.4
            kept.burstNumber = 4
            kept.isBestOfBurst = true
            kept.userVerdictRaw = "review"
            kept.bestOfBurstChosenAt = analyzedAt
            kept.sha256 = "abc"
            let video = CatalogueV1.Photo(id: videoId, relativePath: "C0001.MP4")
            video.mediaKindRaw = "video"
            for photo in [kept, video] {
                context.insert(photo)
                photo.gallery = gallery
            }
            gallery.photoCount = 2
            gallery.videoCount = 1
            gallery.indexedAt = analyzedAt
            gallery.culledAt = analyzedAt
            try context.save()
        }()

        // 2. This version opens the same file.
        let container = try ModelContainer(for: Gallery.self, Photo.self, configurations: ModelConfiguration(url: storeURL))
        let context = ModelContext(container)
        let gallery = try #require(try context.fetch(FetchDescriptor<Gallery>()).first)
        #expect(gallery.id == galleryId)
        #expect(gallery.name == "Séance du 20 sept.")
        #expect(gallery.photoCount == 2 && gallery.videoCount == 1)
        #expect(gallery.culledAt == analyzedAt)
        let photos = try context.fetch(FetchDescriptor<Photo>())
        #expect(Set(photos.map(\.id)) == [keptId, videoId])
        let kept = try #require(photos.first { $0.id == keptId })
        #expect(kept.gallery?.id == galleryId)
        #expect(kept.cullingVerdict == .keep)
        #expect(kept.cullingReasons.map(\.kind) == [.bestOfBurst])
        #expect(kept.userVerdict == .review)
        #expect(kept.bestOfBurstChosenAt == analyzedAt)
        #expect(kept.sharpness == 158.4 && kept.burstNumber == 4 && kept.isBestOfBurst)
        #expect(kept.sha256 == "abc")
        // The new fields are empty, so the background backfill picks the gallery up.
        #expect(kept.detailsReadAt == nil && kept.subjectBox == nil && kept.cameraModel == nil)
        #expect(kept.highlightClipping == nil && kept.videoDuration == nil)
        let store = LibraryStore(modelContainer: container)
        #expect(try await store.galleriesNeedingDetails() == [galleryId])
        #expect(try await store.detailsWork(galleryId: galleryId).items.map(\.photoId).sorted { $0.uuidString < $1.uuidString }
            == [keptId, videoId].sorted { $0.uuidString < $1.uuidString })
    }
}

/// The catalogue models exactly as they were before batch 3 (commit 580014c). Same class names, so
/// SwiftData sees the same entities « Gallery » and « Photo », without the new columns.
enum CatalogueV1 {
    @Model
    final class Gallery {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        var folderPath: String
        var folderBookmark: Data
        var writeBookmark: Data?
        var volumeName: String?
        var volumeUUID: String?
        var photoCount: Int
        var videoCount = 0
        var indexedAt: Date?
        var culledAt: Date?
        @Relationship(deleteRule: .cascade, inverse: \Photo.gallery)
        var photos: [Photo] = []

        init(id: UUID, name: String, folderPath: String) {
            self.id = id
            self.name = name
            createdAt = Date()
            self.folderPath = folderPath
            folderBookmark = Data()
            photoCount = 0
        }
    }

    @Model
    final class Photo {
        #Index<Photo>([\.captureDate])

        @Attribute(.unique) var id: UUID
        var gallery: Gallery?
        var relativePath: String
        var fileSize: Int64
        var captureDate: Date?
        var pixelWidth: Int
        var pixelHeight: Int
        var importedAt: Date
        var mediaKindRaw: String?
        var cullingVerdictRaw: String?
        var cullingReasonsData: Data?
        var analyzedAt: Date?
        var sharpness: Double?
        var aestheticsScore: Double?
        var burstNumber: Int?
        var isBestOfBurst = false
        var userVerdictRaw: String?
        var bestOfBurstChosenAt: Date?
        var sha256: String?

        init(id: UUID, relativePath: String) {
            self.id = id
            self.relativePath = relativePath
            fileSize = 24_903_680
            pixelWidth = 4000
            pixelHeight = 6000
            importedAt = Date()
        }
    }
}
