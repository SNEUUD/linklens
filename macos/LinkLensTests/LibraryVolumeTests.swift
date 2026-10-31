import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// Volume test kept from the prototype: 10 000 photos must stay fast with SwiftData.
/// If it fails, report it: GRDB is the planned fallback.
///
/// Known limit: each `photo.gallery = gallery` makes SwiftData update `Gallery.photos`, which costs
/// more the fuller the gallery is (batch of 200: 0.04 s at first, 0.42 s at 10 000). The insertion
/// time therefore grows with the square of the photo count. Accepted for phase 1 (a session rarely
/// goes past 5 000 photos): strict budget at 5 000, looser one at 10 000 so that it cannot get worse
/// unnoticed. Measured on 2026-10-31: about 3 s at 5 000, 11 to 14 s at 10 000.
struct LibraryVolumeTests {
    @Test func insertsAndQueriesTenThousandPhotos() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let storeURL = folder.url.appending(path: "volume.store")
        let container = try ModelContainer(
            for: Gallery.self, Photo.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await store.createGallery(name: "Volume", folderPath: "/volume", folderBookmark: Data())

        let clock = ContinuousClock()
        let start = clock.now
        let sessionStart = Date(timeIntervalSince1970: 1_780_000_000)
        var fiveThousandDuration: Duration?
        for batchStart in stride(from: 0, to: 10_000, by: 200) {
            if batchStart == 5_000 { fiveThousandDuration = start.duration(to: clock.now) }
            let drafts = (batchStart..<batchStart + 200).map { index in
                PhotoDraft(
                    file: PhotoFile(
                        url: URL(filePath: "/volume/DSC\(index).ARW"),
                        relativePath: "DSC\(index).ARW",
                        fileSize: 25_000_000
                    ),
                    metadata: PhotoMetadata(
                        captureDate: sessionStart.addingTimeInterval(Double(index) * 1.5),
                        pixelWidth: 6000,
                        pixelHeight: 4000
                    ),
                    importedAt: Date()
                )
            }
            try await store.insert(drafts, galleryId: galleryId)
        }
        try await store.finishIndexing(galleryId: galleryId)
        let insertDuration = start.duration(to: clock.now)

        let context = ModelContext(container)
        let queryStart = clock.now
        var descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { $0.gallery?.id == galleryId },
            sortBy: [SortDescriptor(\.captureDate)]
        )
        descriptor.fetchLimit = 50
        let firstPhotos = try context.fetch(descriptor)
        let queryDuration = queryStart.duration(to: clock.now)

        #expect(try context.fetchCount(FetchDescriptor<Photo>()) == 10_000)
        #expect(try context.fetch(FetchDescriptor<Gallery>()).first?.photoCount == 10_000)
        #expect(firstPhotos.first?.relativePath == "DSC0.ARW")
        let halfway = try #require(fiveThousandDuration)
        #expect(halfway < .seconds(5), "insertion de 5 000 photos : \(halfway)")
        #expect(insertDuration < .seconds(20), "insertion de 10 000 photos : \(insertDuration)")
        #expect(queryDuration < .milliseconds(200), "requête des 50 premières photos : \(queryDuration)")
    }
}
