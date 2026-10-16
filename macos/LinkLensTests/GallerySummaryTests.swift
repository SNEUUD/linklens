import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// What the sidebar shows about a gallery: counts, the verdict bar, the cover, the folder path.
struct GallerySummaryTests {
    private typealias Item = GallerySummary.Item

    // MARK: - Counts

    @Test func countsPhotosVideosAndBursts() {
        let summary = GallerySummary([
            Item(id: UUID(), verdict: .keep, burstNumber: 1),
            Item(id: UUID(), verdict: .reject, burstNumber: 1),
            Item(id: UUID(), verdict: .review, burstNumber: 2),
            Item(id: UUID(), verdict: .keep),
            Item(id: UUID(), isVideo: true),
        ])

        #expect(summary.photoCount == 4, "videos are counted apart")
        #expect(summary.videoCount == 1)
        #expect(summary.burstCount == 2)
        #expect(summary.counts == VerdictCounts(keep: 2, review: 1, reject: 1))
        #expect(summary.unsortedCount == 0, "a video is never sorted, and never « not sorted yet »")
    }

    @Test func theSessionOfSeptember20() {
        // The 52 RAW of ~/Downloads/photos as the AI sorted them: 12 / 14 / 26, 12 bursts.
        let items = (0..<52).map { index in
            Item(
                id: UUID(),
                verdict: index < 12 ? .keep : index < 26 ? .review : .reject,
                burstNumber: index < 48 ? index / 4 + 1 : nil
            )
        }
        let summary = GallerySummary(items)

        #expect(summary.photoCount == 52)
        #expect(summary.burstCount == 12)
        #expect(summary.verdictBarDescription == "12 à garder, 14 à revoir, 26 à rejeter")
        #expect(summary.verdictSegments == [
            VerdictSegment(verdict: .keep, count: 12),
            VerdictSegment(verdict: .review, count: 14),
            VerdictSegment(verdict: .reject, count: 26),
        ])
    }

    @MainActor
    @Test func theBarCountsTheUserChoices() throws {
        // Stored photos: the summary reads `Photo.verdict`, the user's choice over the AI's proposal.
        let container = try ModelContainer(for: Gallery.self, Photo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let photos = ["keep", "reject", "reject"].map { verdict in
            let photo = Photo(draft: PhotoDraft(
                file: PhotoFile(url: URL(filePath: "/tmp/a.jpg"), relativePath: "a.jpg", fileSize: 1),
                metadata: PhotoMetadata(captureDate: nil, pixelWidth: 1, pixelHeight: 1),
                importedAt: .now
            ))
            photo.cullingVerdictRaw = verdict
            container.mainContext.insert(photo)
            return photo
        }
        photos[1].userVerdictRaw = "keep"

        let summary = GallerySummary(photos.map(\.summaryItem))

        #expect(summary.counts == VerdictCounts(keep: 2, review: 0, reject: 1))
        #expect(summary.verdictBarDescription == "2 à garder, 0 à revoir, 1 à rejeter")
    }

    @Test func photosNotSortedYetAreGreyAndSaid() {
        let summary = GallerySummary([
            Item(id: UUID(), verdict: .keep),
            Item(id: UUID(), verdict: nil),
            Item(id: UUID(), verdict: .unknown),
        ])

        #expect(summary.isSorted)
        #expect(summary.unsortedCount == 2, "a verdict from a newer version is not shown as a colour")
        #expect(summary.verdictSegments == [
            VerdictSegment(verdict: .keep, count: 1),
            VerdictSegment(verdict: nil, count: 2),
        ])
        #expect(summary.verdictBarDescription == "1 à garder, 0 à revoir, 0 à rejeter, 2 pas encore triées")
    }

    @Test func aGalleryNeverSortedHasNoColouredBar() {
        let summary = GallerySummary([Item(id: UUID()), Item(id: UUID())])

        #expect(!summary.isSorted)
        #expect(summary.verdictSegments == [VerdictSegment(verdict: nil, count: 2)])
        #expect(summary.verdictBarDescription == "Pas encore triée")
    }

    @Test func anEmptyGallery() {
        let summary = GallerySummary([])

        #expect(summary.photoCount == 0)
        #expect(summary.verdictSegments.isEmpty)
        #expect(summary.coverCandidates.isEmpty)
    }

    // MARK: - Cover

    @Test func theCoverIsTheBestPhotoToKeep() {
        let first = Item(id: UUID(), verdict: .reject, aestheticsScore: 0.9)
        let good = Item(id: UUID(), verdict: .keep, aestheticsScore: 0.2)
        let best = Item(id: UUID(), verdict: .keep, aestheticsScore: 0.6)
        let unscored = Item(id: UUID(), verdict: .keep)
        let review = Item(id: UUID(), verdict: .review, aestheticsScore: 0.8)

        let candidates = GallerySummary([first, good, best, unscored, review]).coverCandidates

        #expect(candidates == [best.id, good.id, unscored.id, first.id, review.id],
                "keepers by score, then every other photo in the gallery order")
    }

    @Test func anUnsortedGalleryShowsItsFirstPhoto() {
        let photos = (0..<3).map { _ in Item(id: UUID()) }
        #expect(GallerySummary(photos).coverCandidates.first == photos[0].id)
    }

    @Test func videosComeLastAndCandidatesAreFew() {
        let video = Item(id: UUID(), isVideo: true)
        let photo = Item(id: UUID())
        #expect(GallerySummary([video, photo]).coverCandidates == [photo.id, video.id])

        let many = (0..<500).map { _ in Item(id: UUID()) }
        #expect(GallerySummary(many).coverCandidates.count == GallerySummary.coverCandidateLimit)
    }

    @Test func theCoverIsTheFirstCandidateWithACachedThumbnail() {
        let ids = (0..<3).map { _ in UUID() }

        #expect(GallerySummary.cover(among: ids, cached: Set(ids)) == ids[0])
        #expect(GallerySummary.cover(among: ids, cached: [ids[2], ids[1]]) == ids[1], "best not cached yet: the next one")
        #expect(GallerySummary.cover(among: ids, cached: []) == nil)
    }

    @Test func theCoverIsReadFromTheThumbnailCache() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let cache = ThumbnailCache(directory: folder.url)
        let ids = (0..<3).map { _ in UUID() }
        let image = try #require(ThumbnailGenerator.decodeJPEG(at: folder.writeJPEG("source.jpg")))
        try cache.store(image, for: ids[1])

        let missing = Set(cache.missing(among: ids))
        let cover = GallerySummary.cover(among: ids, cached: Set(ids).subtracting(missing))

        #expect(cover == ids[1])
    }

    // MARK: - Folder path

    @Test func pathsInTheHomeFolderStartWithATilde() {
        #expect(abbreviatedPath("/Users/chris/Downloads/photos", home: "/Users/chris") == "~/Downloads/photos")
        #expect(abbreviatedPath("/Users/chris", home: "/Users/chris/") == "~")
        #expect(abbreviatedPath("/Users/christine/photos", home: "/Users/chris") == "/Users/christine/photos")
        #expect(abbreviatedPath("/Volumes/Photos 2TB/2026", home: "/Users/chris") == "/Volumes/Photos 2TB/2026")
    }

    @Test func theRealHomeIsNotTheSandboxContainer() {
        #expect(!realHomeDirectory().contains("/Library/Containers/"))
    }
}
