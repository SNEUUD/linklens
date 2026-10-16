import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// Batch 3: the details the inspector shows (EXIF, subject box, exposure), read at indexing time, stored
/// by the analysis, and filled in later for photos analysed before (`DetailsBackfiller`).
struct InspectorDetailsTests {
    /// A 240 px JPEG made from DSC04311.ARW of the real session, with its EXIF kept (Sony A6000).
    static func exifFixture() throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        return try #require(
            bundle.url(forResource: "DSC04311-exif", withExtension: "jpg")
                ?? bundle.url(forResource: "DSC04311-exif", withExtension: "jpg", subdirectory: "EXIF")
                ?? bundle.url(forResource: "DSC04311-exif", withExtension: "jpg", subdirectory: "Fixtures/EXIF"),
            "DSC04311-exif.jpg missing from the test bundle"
        )
    }

    // MARK: - EXIF

    @Test func readsCameraLensAndSettingsFromTheFixture() throws {
        let metadata = PhotoMetadataReader.read(url: try Self.exifFixture())
        #expect(metadata.capture == CaptureInfo(
            cameraMake: "SONY", cameraModel: "ILCE-6000", lensModel: "E 55-210mm F4.5-6.3 OSS",
            exposureTime: 0.00625, fNumber: 10, iso: 100, focalLength: 173
        ))
        let expectedDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 14, minute: 41, second: 6))
        #expect(metadata.captureDate == expectedDate)
        #expect(metadata.pixelWidth == 160 && metadata.pixelHeight == 240)
    }

    @Test func aFileWithoutExifHasNoSettings() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let plain = try folder.writeJPEG("plain.jpg")
        #expect(PhotoMetadataReader.read(url: plain).capture == CaptureInfo())
    }

    @Test func indexingStoresTheExif() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try FileManager.default.copyItem(at: try Self.exifFixture(), to: folder.url.appending(path: "DSC04311.jpg"))
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        _ = try await FolderIndexer(store: store).indexFolder(at: folder.url)

        let photo = try #require(try ModelContext(container).fetch(FetchDescriptor<Photo>()).first)
        #expect(photo.cameraModel == "ILCE-6000")
        #expect(photo.lensModel == "E 55-210mm F4.5-6.3 OSS")
        #expect(photo.exposureTime == 0.00625)
        #expect(photo.iso == 100)
        // Not analysed yet: the measured details are still to come.
        #expect(photo.detailsReadAt == nil)
        #expect(photo.subjectBox == nil)
    }

    // MARK: - Storing the box

    @MainActor
    @Test func subjectBoxRoundTripsThroughTheCatalogue() throws {
        let container = try makeInMemoryContainer()
        let photo = Self.insertPhoto("a.ARW", in: container.mainContext)
        let box = CGRect(x: 0.1029, y: 0.3435, width: 0.6593, height: 0.1951)
        try photo.apply(
            CullingResult(
                photoId: photo.id, verdict: .keep, reasons: [CullingReason(kind: .noIssue, verdict: .keep)],
                measured: PhotoDetails.Measured(subjectBox: box, highlightClipping: 0.01, shadowClipping: 0.002),
                capture: CaptureInfo(cameraMake: "SONY", iso: 100)
            ),
            analyzedAt: .now
        )
        try container.mainContext.save()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Photo>()).first)
        #expect(stored.subjectBox == box)
        #expect(stored.highlightClipping == 0.01)
        #expect(stored.shadowClipping == 0.002)
        #expect(stored.cameraMake == "SONY")
        #expect(stored.detailsReadAt != nil)
        // The F5 trash keeps the details for « Annuler ».
        #expect(Photo(snapshot: stored.snapshot).snapshot == stored.snapshot)
    }

    @MainActor
    @Test func anUnreadablePhotoKeepsWhatWasKnown() throws {
        let container = try makeInMemoryContainer()
        let photo = Self.insertPhoto("a.ARW", in: container.mainContext)
        photo.subjectBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        photo.highlightClipping = 0.05
        try photo.apply(Classifier.failedResult(photoId: photo.id), analyzedAt: .now)
        #expect(photo.subjectBox == CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(photo.highlightClipping == 0.05)
    }

    @Test func sortingStoresTheSameBoxAsTheBackfillReads() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try FileManager.default.copyItem(at: try Self.exifFixture(), to: folder.url.appending(path: "DSC04311.jpg"))
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await Self.indexedGallery(folder, store: store)
        _ = try await GalleryCuller(store: store).cullGallery(id: galleryId)

        let photo = try #require(try ModelContext(container).fetch(FetchDescriptor<Photo>()).first)
        #expect(photo.detailsReadAt != nil)
        #expect(photo.highlightClipping != nil && photo.shadowClipping != nil)
        #expect(photo.cameraModel == "ILCE-6000")
        // The backfill measures exactly what the sorting measured.
        let measured = try await DetailsBackfiller.measure(
            url: folder.url.appending(path: "DSC04311.jpg"), thresholds: CullingThresholds()
        )
        #expect(measured.subjectBox == photo.subjectBox)
        #expect(measured.highlightClipping == photo.highlightClipping)
        #expect(measured.shadowClipping == photo.shadowClipping)
    }

    // MARK: - Backfill

    @Test func backfillFillsTheDetailsAndNeverTouchesVerdictsOrChoices() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try FileManager.default.copyItem(at: try Self.exifFixture(), to: folder.url.appending(path: "DSC04311.jpg"))
        try folder.writeJPEG("flat.jpg", width: 1200, height: 800)
        try folder.writeFile("broken.ARW")
        let before = try folder.snapshot()
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await Self.indexedGallery(folder, store: store)
        _ = try await GalleryCuller(store: store).cullGallery(id: galleryId)

        // What the sorting stored, then the catalogue as it was before batch 3: no details, and
        // choices of the user on top.
        let context = ModelContext(container)
        let photos = try context.fetch(FetchDescriptor<Photo>())
        let expectedDetails = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, DetailsValues($0)) })
        for photo in photos {
            photo.capture = CaptureInfo()
            photo.subjectBox = nil
            photo.highlightClipping = nil
            photo.shadowClipping = nil
            photo.detailsReadAt = nil
        }
        photos[0].userVerdictRaw = "reject"
        photos[1].bestOfBurstChosenAt = Date(timeIntervalSince1970: 1_000)
        try context.save()
        let verdictsBefore = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, VerdictValues($0)) })
        #expect(try await store.galleriesNeedingDetails() == [galleryId])

        let done = try await DetailsBackfiller(store: store, batchSize: 2).fillDetails(galleryId: galleryId)
        #expect(done == 3)

        let after = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        for photo in after {
            #expect(VerdictValues(photo) == verdictsBefore[photo.id], "verdicts, reasons and choices unchanged")
            #expect(DetailsValues(photo) == expectedDetails[photo.id], "the same details as the sorting")
            #expect(photo.detailsReadAt != nil, "read once, even the broken file")
        }
        #expect(try await store.galleriesNeedingDetails().isEmpty)
        #expect(try folder.snapshot() == before, "the files are only read")
    }

    @Test func backfillWritesNothingWhenTheFolderIsGone() async throws {
        let folder = try TestFolder()
        try folder.writeJPEG("a.jpg", width: 1200, height: 800)
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await Self.indexedGallery(folder, store: store)
        _ = try await GalleryCuller(store: store).cullGallery(id: galleryId)
        let context = ModelContext(container)
        let photo = try #require(try context.fetch(FetchDescriptor<Photo>()).first)
        photo.detailsReadAt = nil
        try context.save()

        folder.remove() // Like an unplugged disk (F9).
        await #expect(throws: (any Error).self) {
            _ = try await DetailsBackfiller(store: store).fillDetails(galleryId: galleryId)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Photo>()).first?.detailsReadAt == nil)
    }

    @MainActor
    @Test func controllerSkipsUnreachableGalleriesThenFillsThem() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("a.jpg", width: 1200, height: 800)
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await Self.indexedGallery(folder, store: store)
        _ = try await GalleryCuller(store: store).cullGallery(id: galleryId)
        let context = ModelContext(container)
        try #require(try context.fetch(FetchDescriptor<Photo>()).first).detailsReadAt = nil
        try context.save()

        let controller = DetailsBackfillController(store: store)
        var reachable = false
        controller.canRead = { _ in reachable }
        await controller.fillPendingGalleries().value
        await controller.waitUntilIdle()
        #expect(try await store.galleriesNeedingDetails() == [galleryId], "disk unplugged: skipped")

        reachable = true // The disk is back: the app asks again.
        await controller.fillPendingGalleries().value
        await controller.waitUntilIdle()
        #expect(try await store.galleriesNeedingDetails().isEmpty)
        #expect(controller.runningGalleryId == nil && controller.progress == nil)
    }

    @MainActor
    @Test func cancellingStopsUntilTheNextLaunch() async throws {
        let container = try makeInMemoryContainer()
        let controller = DetailsBackfillController(store: LibraryStore(modelContainer: container))
        controller.cancel()
        #expect(controller.isCancelled)
        await controller.fillPendingGalleries().value
        #expect(controller.runningGalleryId == nil)
    }

    // MARK: - Helpers

    @MainActor
    static func insertPhoto(_ name: String, in context: ModelContext) -> Photo {
        let photo = Photo(draft: PhotoDraft(
            file: PhotoFile(url: URL(filePath: "/tmp/\(name)"), relativePath: name, fileSize: 1),
            metadata: .unknown, importedAt: .now
        ))
        context.insert(photo)
        return photo
    }

    static func indexedGallery(_ folder: TestFolder, store: LibraryStore) async throws -> UUID {
        guard case .indexed(let galleryId, _) = try await FolderIndexer(store: store).indexFolder(at: folder.url) else {
            throw LibraryError.galleryNotFound
        }
        return galleryId
    }
}

/// Everything the backfill must leave alone.
private struct VerdictValues: Equatable {
    var verdict: String?
    var reasons: Data?
    var analyzedAt: Date?
    var sharpness: Double?
    var aesthetics: Double?
    var burstNumber: Int?
    var isBestOfBurst: Bool
    var userVerdict: String?
    var bestChosenAt: Date?

    init(_ photo: Photo) {
        verdict = photo.cullingVerdictRaw
        reasons = photo.cullingReasonsData
        analyzedAt = photo.analyzedAt
        sharpness = photo.sharpness
        aesthetics = photo.aestheticsScore
        burstNumber = photo.burstNumber
        isBestOfBurst = photo.isBestOfBurst
        userVerdict = photo.userVerdictRaw
        bestChosenAt = photo.bestOfBurstChosenAt
    }
}

/// What the backfill fills in.
private struct DetailsValues: Equatable {
    var capture: CaptureInfo
    var subjectBox: CGRect?
    var highlights: Double?
    var shadows: Double?

    init(_ photo: Photo) {
        capture = photo.capture
        subjectBox = photo.subjectBox
        highlights = photo.highlightClipping
        shadows = photo.shadowClipping
    }
}

/// `Bundle(for:)` needs a class of the test bundle.
private final class BundleToken {}
