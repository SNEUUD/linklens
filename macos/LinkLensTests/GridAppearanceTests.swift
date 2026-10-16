import Foundation
import Testing
@testable import LinkLens

/// Shape and size of the grid cells, and the progress pill that gathers the background work.
struct GridAppearanceTests {
    // MARK: - Dominant orientation

    @Test func portraitSessionGetsPortraitCells() {
        // The A6000 RAW files are stored 4000 × 6000 (EXIF orientation 8 already applied).
        let sizes = Array(repeating: (width: 4000, height: 6000), count: 50) + [(6000, 4000), (6000, 4000)]

        #expect(abs(ThumbnailShape.cellAspectRatio(sizes: sizes) - 2.0 / 3.0) < 0.01)
    }

    @Test func landscapeAndPhoneShapesAreKept() {
        #expect(abs(ThumbnailShape.cellAspectRatio(sizes: [(6000, 4000), (6000, 4000), (4000, 6000)]) - 1.5) < 0.01)
        // A phone: 3:4 portraits.
        #expect(abs(ThumbnailShape.cellAspectRatio(sizes: [(3024, 4032), (3024, 4032), (4000, 6000)]) - 0.75) < 0.01)
    }

    @Test func unknownSizesAreIgnored() {
        #expect(ThumbnailShape.cellAspectRatio(sizes: []) == ThumbnailShape.defaultAspectRatio)
        #expect(ThumbnailShape.cellAspectRatio(sizes: [(0, 0), (0, 0)]) == ThumbnailShape.defaultAspectRatio)
        #expect(abs(ThumbnailShape.cellAspectRatio(sizes: [(0, 0), (0, 0), (0, 0), (4000, 6000)]) - 2.0 / 3.0) < 0.01)
    }

    @Test func aTieOrSquaresGiveSquareCells() {
        #expect(ThumbnailShape.cellAspectRatio(sizes: [(4000, 6000), (6000, 4000)]) == 1)
        #expect(ThumbnailShape.cellAspectRatio(sizes: [(1000, 1000), (1000, 1000), (6000, 4000)]) == 1)
    }

    @Test func extremeShapesAreClamped() {
        // Panoramas: cells no wider than 2:1.
        #expect(ThumbnailShape.cellAspectRatio(sizes: [(12000, 3000)]) == 2)
    }

    @Test func onlyPhotosOfTheCellShapeFillIt() {
        #expect(ThumbnailShape.fillsCell(photoAspectRatio: 2.0 / 3.0, cellAspectRatio: 2.0 / 3.0))
        #expect(ThumbnailShape.fillsCell(photoAspectRatio: 534.0 / 800.0, cellAspectRatio: 2.0 / 3.0), "a rounded thumbnail size")
        let portraitCell: CGFloat = 2.0 / 3.0
        let landscapeInPortrait = ThumbnailShape.fillsCell(photoAspectRatio: 1.5, cellAspectRatio: portraitCell)
        let phoneInCamera = ThumbnailShape.fillsCell(photoAspectRatio: 0.75, cellAspectRatio: portraitCell)
        #expect(landscapeInPortrait == false, "a landscape photo is shown whole")
        #expect(phoneInCamera == false, "cropping 11 % could hide a cut subject")
        #expect(ThumbnailShape.fillsCell(photoAspectRatio: 0, cellAspectRatio: 1) == false)
    }

    // MARK: - Thumbnail size

    @Test func zoomStepsStayInTheRange() {
        #expect(ThumbnailSize.zoomed(180, steps: 1) == 200)
        #expect(ThumbnailSize.zoomed(180, steps: -1) == 160)
        #expect(ThumbnailSize.zoomed(187, steps: 1) == 200, "a value between two steps snaps first")
        #expect(ThumbnailSize.zoomed(320, steps: 1) == 320)
        #expect(ThumbnailSize.zoomed(120, steps: -1) == 120)
        #expect(ThumbnailSize.zoomed(10, steps: 0) == 120)
    }

    @Test func biggerThumbnailsGiveFewerColumns() {
        let width: CGFloat = 1000
        let small = GridLayout.columnCount(forWidth: width, minimumCellWidth: 120)
        let standard = GridLayout.columnCount(forWidth: width, minimumCellWidth: 180)
        let large = GridLayout.columnCount(forWidth: width, minimumCellWidth: 320)

        #expect(small > standard)
        #expect(standard > large)
        #expect(large >= 1)
    }

    // MARK: - Progress pill

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func nothingRunningHidesThePill() {
        #expect(ActivityPill.content(for: []) == nil)
    }

    @Test func theExportReadsAsInTheMockup() {
        let export = Activity.export(ExportProgress(galleryId: UUID(), preset: .webJPEG, completed: 8, total: 26), startedAt: start)

        #expect(export.text == "Export « JPEG pour le web » · 8 sur 26")
        #expect(abs((export.fraction ?? 0) - 8.0 / 26.0) < 0.001)
        #expect(export.isCancellable)
    }

    @Test func theMostRecentActivityIsShownWithTheOthersCounted() throws {
        let galleryId = UUID()
        let culling = Activity.culling(CullingProgress(galleryId: galleryId, completed: 10, total: 52), isQueued: false, startedAt: start)
        let export = Activity.export(ExportProgress(galleryId: galleryId, preset: .heic, completed: 0, total: 12), startedAt: start + 30)
        let duplicates = Activity.duplicates(nil, startedAt: start + 10)

        let content = try #require(ActivityPill.content(for: [culling, export, duplicates]))

        #expect(content.shown.kind == .export)
        #expect(content.others.map(\.kind) == [.duplicates, .culling], "most recent first")
        #expect(content.othersBadge == "+2")
        #expect(ActivityPill.content(for: [culling])?.othersBadge == nil)
    }

    @Test func aWaitingSortingGivesWayToWhatRuns() {
        let waiting = Activity.culling(nil, isQueued: true, startedAt: nil)
        let indexing = Activity.indexing(IndexingProgress(galleryId: UUID(), completed: 9, total: 24), startedAt: start)

        let content = ActivityPill.content(for: [waiting, indexing])

        #expect(content?.shown.kind == .indexing)
        #expect(content?.shown.text == "Indexation du dossier · 9 sur 24")
        #expect(content?.others.first?.text == "Tri en attente")
        #expect(waiting.fraction == nil, "no bar to fill: the indicator spins")
    }

    @Test func equalDatesAlwaysGiveTheSameOrder() {
        let culling = Activity.culling(nil, isQueued: false, startedAt: start)
        let export = Activity.export(ExportProgress(galleryId: UUID(), preset: .tiff, completed: 1, total: 2), startedAt: start)

        #expect(ActivityPill.content(for: [culling, export])?.shown.kind == .export)
        #expect(ActivityPill.content(for: [export, culling])?.shown.kind == .export)
    }

    @Test func aFinishedExportIsShownUntilClosed() {
        let destination = URL(filePath: "/Users/chris/Desktop/Export", directoryHint: .isDirectory)
        let complete = ExportSummary(
            galleryId: UUID(), preset: .webJPEG, destination: destination,
            exportedFiles: (0..<26).map { destination.appending(path: "\($0).jpg") }, failures: [], wasCancelled: false
        )
        var partial = complete
        partial.failures = [ExportFailure(relativePath: "a.ARW", message: "Illisible")]

        let done = Activity.exportFinished(complete, at: start + 60)
        let warning = Activity.exportFinished(partial, at: start + 60)

        #expect(done.text == "Export terminé : 26 photos dans « Export »")
        #expect(!done.isCancellable && !done.isWarning)
        #expect(warning.isWarning)
        #expect(warning.detail == "Illisible")
        #expect(warning.text.hasSuffix("Échecs : 1"))
        // A sorting started before the end of the export stays behind « +1 ».
        let culling = Activity.culling(nil, isQueued: false, startedAt: start + 10)
        #expect(ActivityPill.content(for: [culling, done])?.shown.kind == .exportFinished)
    }
}
