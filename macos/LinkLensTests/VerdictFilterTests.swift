import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// The verdict filters above the photos: counts, bursts unfolded under a filter, and what happens
/// to a photo sorted out of the filter while it is on.
@MainActor
struct VerdictFilterTests {
    /// Photos described by their verdict and burst: `(.review, 2, true)` = best photo of burst 2, « À revoir ».
    private func photos(_ specs: [(CullingVerdict?, Int?, Bool)]) -> [BurstStacks.Input] {
        specs.map { verdict, burst, isBest in
            BurstStacks.Input(id: UUID(), burstNumber: burst, isBestOfBurst: isBest, verdict: verdict)
        }
    }

    // MARK: - Counts

    @Test func countsFollowTheUsersChoices() throws {
        // Stored photos, as in the app: a model object must belong to a container of its own here,
        // never to the app's real catalogue (the tests run inside the app).
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        func photo(ai: String?, user: String? = nil) -> Photo {
            let photo = Photo(draft: PhotoDraft(
                file: PhotoFile(url: URL(filePath: "/tmp/a.ARW"), relativePath: "a.ARW", fileSize: 1),
                metadata: .unknown, importedAt: Date()
            ))
            context.insert(photo)
            photo.cullingVerdictRaw = ai
            photo.userVerdictRaw = user
            return photo
        }
        let gallery = [
            photo(ai: "keep"), photo(ai: "reject", user: "keep"), photo(ai: "review"),
            photo(ai: "review", user: "reject"), photo(ai: nil), photo(ai: "favourite"),
        ]

        let counts = VerdictFilterCounts(gallery.map(\.verdict))
        withExtendedLifetime(container) {}

        #expect(counts == VerdictFilterCounts(all: 6, keep: 2, review: 1, reject: 1))
        #expect(counts.title(of: .all) == "Toutes · 6")
        #expect(counts.title(of: .keep) == "Garder · 2")
        #expect(counts.title(of: .review) == "À revoir · 1")
        #expect(counts.accessibilityLabel(of: .review) == "À revoir, 1 photo")
        #expect(counts.accessibilityLabel(of: .all) == "Toutes, 6 photos")
    }

    @Test func unsortedPhotosOnlyAppearUnderAll() {
        #expect(VerdictFilter.all.matches(nil))
        #expect(VerdictFilter.all.matches(.unknown))
        #expect(!VerdictFilter.review.matches(nil))
        #expect(!VerdictFilter.review.matches(.unknown))
        #expect(VerdictFilter.review.matches(.review))
        #expect(!VerdictFilter.keep.matches(.review))
        #expect(VerdictFilter.allCases.map(\.shortcutDigit) == ["1", "2", "3", "4"])
    }

    // MARK: - Bursts under a filter

    @Test func allKeepsTheBurstsStacked() {
        let input = photos([(.keep, nil, false), (.review, 1, false), (.keep, 1, true), (.review, 1, false)])

        let entries = BurstStacks.entries(for: input, expanded: [], filter: .all)

        #expect(entries == BurstStacks.entries(for: input, expanded: []))
        #expect(entries.map(\.photoIndex) == [0, 2])
    }

    @Test func aFilterUnfoldsTheBursts() {
        // single keep, burst 1 of 4 (best = index 2, keep; two « À revoir »), single review.
        let input = photos([
            (.keep, nil, false), (.review, 1, false), (.keep, 1, true), (.review, 1, false), (.reject, 1, false),
            (.review, nil, false),
        ])

        let review = BurstStacks.entries(for: input, expanded: [], filter: .review)

        #expect(review.map(\.photoIndex) == [1, 3, 5], "every « À revoir » photo, even inside a collapsed burst")
        #expect(review[0].burst == BurstPlacement(number: 1, count: 4, isExpanded: true, isCover: false, isShownAlone: true))
        #expect(review[2].burst == nil)
        #expect(review.allSatisfy { !$0.isOutsideFilter })

        let keep = BurstStacks.entries(for: input, expanded: [], filter: .keep)
        #expect(keep.map(\.photoIndex) == [0, 2])
        #expect(keep[1].burst?.isCover == true, "the best photo keeps its star")
        #expect(BurstStacks.entries(for: input, expanded: [], filter: .reject).map(\.photoIndex) == [4])
    }

    @Test func retainedPhotosStayInPlaceMarkedOutsideTheFilter() {
        let input = photos([(.review, nil, false), (.keep, nil, false), (.review, nil, false)])

        let entries = BurstStacks.entries(for: input, expanded: [], filter: .review, retaining: [input[1].id])

        #expect(entries.map(\.photoIndex) == [0, 1, 2])
        #expect(entries.map(\.isOutsideFilter) == [false, true, false])
    }

    // MARK: - Browser

    private func browser(_ input: [BurstStacks.Input], filter: VerdictFilter) -> GalleryBrowser {
        let browser = GalleryBrowser()
        browser.setPhotos(input)
        browser.setFilter(filter)
        return browser
    }

    /// The same photos with one verdict changed, as `@Query` gives them after a key press.
    private func changing(_ input: [BurstStacks.Input], _ index: Int, to verdict: CullingVerdict) -> [BurstStacks.Input] {
        var changed = input
        changed[index].verdict = verdict
        return changed
    }

    @Test func aPhotoSortedOutOfTheFilterStaysUntilTheFilterChanges() {
        var input = photos([(.review, nil, false), (.review, nil, false), (.review, nil, false)])
        let browser = browser(input, filter: .review)
        browser.selection = input[0].id

        // P on the first photo, then the selection moves on (as the key does).
        input = changing(input, 0, to: .keep)
        browser.setPhotos(input)
        browser.showNeighbour(offset: 1)

        #expect(browser.photoIds == input.map(\.id), "nothing moves under the cursor")
        #expect(browser.entries.map(\.isOutsideFilter) == [true, false, false], "drawn dimmed")
        #expect(browser.selection == input[1].id)

        // Moving around or sorting another photo does not remove it either.
        browser.move(.right)
        input = changing(input, 2, to: .reject)
        browser.setPhotos(input)
        #expect(browser.photoIds == input.map(\.id))
        #expect(browser.entries.map(\.isOutsideFilter) == [true, false, true])

        // Choosing the filter again (or another one) applies it afresh.
        browser.setFilter(.review)
        #expect(browser.photoIds == [input[1].id])
    }

    @Test func aPhotoThatNowMatchesAppearsInItsPlace() {
        var input = photos([(.review, nil, false), (.keep, nil, false), (.review, nil, false)])
        let browser = browser(input, filter: .review)
        #expect(browser.photoIds == [input[0].id, input[2].id])

        // E.g. ⌘Z of a « Garder » chosen under « Toutes ».
        input = changing(input, 1, to: .review)
        browser.setPhotos(input)

        #expect(browser.photoIds == input.map(\.id))
    }

    @Test func changingTheFilterSelectsTheNearestShownPhoto() {
        let input = photos([(.review, nil, false), (.keep, nil, false), (.keep, nil, false), (.review, nil, false), (.reject, nil, false)])
        let browser = browser(input, filter: .all)
        browser.selection = input[1].id

        browser.setFilter(.review)
        #expect(browser.selection == input[3].id, "the next « À revoir » photo after the selected one")

        browser.setFilter(.all)
        #expect(browser.selection == input[3].id, "still shown: kept")

        browser.selection = input[4].id
        browser.setFilter(.keep)
        #expect(browser.selection == input[2].id, "none after it: the last one shown")

        browser.setFilter(.reject)
        #expect(browser.selection == input[4].id)
        browser.setFilter(.review)
        #expect(browser.selection == input[3].id)
    }

    @Test func sUnderAFilterShowsTheWholeBurstUnderAll() {
        let input = photos([(.keep, 1, true), (.review, 1, false), (.review, 1, false), (.keep, nil, false)])
        let browser = browser(input, filter: .review)
        browser.selection = input[2].id

        #expect(browser.toggleSelectedBurst())

        #expect(browser.filter == .all)
        #expect(browser.expandedBursts == [1])
        #expect(browser.selection == input[2].id, "the same photo, now among its burst")
        #expect(browser.photoIds == input.map(\.id))
    }

    @Test func goingBackToAllSelectsTheStackOfACollapsedBurst() {
        let input = photos([(.keep, 1, true), (.review, 1, false), (.keep, nil, false)])
        let browser = browser(input, filter: .review)
        browser.selection = input[1].id

        browser.setFilter(.all)

        #expect(browser.selection == input[0].id)
    }

    @Test func aNewSortingAppliesTheFilterAfresh() {
        var input = photos([(.review, nil, false), (.review, nil, false)])
        let browser = browser(input, filter: .review)
        input = changing(input, 0, to: .keep)
        browser.setPhotos(input)
        #expect(browser.photoIds.count == 2)

        browser.gallerySortedAgain()

        #expect(browser.photoIds == [input[1].id])
    }

    // MARK: - With the real sorter and undo

    @Test func keysUnderAFilterSortAdvanceAndUndo() throws {
        let fixture = try SortingFixture(aiVerdicts: [.review, .keep, .review, .review])
        let ids = fixture.photos.map(\.id)
        fixture.browser.setFilter(.review)
        #expect(fixture.browser.photoIds == [ids[0], ids[2], ids[3]])
        fixture.browser.selection = ids[0]

        fixture.press(.choose(.keep))

        #expect(fixture.browser.photoIds == [ids[0], ids[2], ids[3]], "the sorted photo stays")
        #expect(fixture.browser.entries.first?.isOutsideFilter == true)
        #expect(fixture.browser.selection == ids[2], "the key moved on to the next « À revoir » photo")

        fixture.press(.choose(.reject))
        #expect(fixture.browser.selection == ids[3])

        fixture.undoManager.undo()
        fixture.refresh()
        #expect(fixture.browser.selection == ids[2], "undo selects the photo again: it is still shown")
        #expect(fixture.photos[2].verdict == .review)
        #expect(fixture.browser.entries.map(\.isOutsideFilter) == [true, false, false])

        fixture.undoManager.undo()
        fixture.refresh()
        #expect(fixture.browser.selection == ids[0])
        #expect(fixture.browser.entries.map(\.isOutsideFilter) == [false, false, false])
    }

    @Test func bChoosesTheBestPhotoOfABurstUnderAFilter() throws {
        let fixture = try SortingFixture(aiVerdicts: [.keep, .review, .review], burst: (number: 1, best: 0))
        let ids = fixture.photos.map(\.id)
        fixture.browser.setFilter(.review)
        fixture.browser.selection = ids[2]

        #expect(fixture.pressB())

        #expect(fixture.browser.photoIds == [ids[1], ids[2]])
        #expect(fixture.browser.selectedEntry?.burst?.isCover == true)
        #expect(fixture.browser.selectedEntry?.burst?.isCoverChosenByUser == true)
    }

    // MARK: - Remembered per gallery

    @Test func theFilterIsRememberedPerGallery() throws {
        let suiteName = "VerdictFilterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VerdictFilterStore(defaults: defaults)
        let (first, second) = (UUID(), UUID())

        #expect(store.filter(galleryId: first) == .all, "« Toutes » by default")
        store.setFilter(.review, galleryId: first)
        store.setFilter(.reject, galleryId: second)
        #expect(store.filter(galleryId: first) == .review)
        #expect(store.filter(galleryId: second) == .reject)

        store.setFilter(.all, galleryId: first)
        #expect(store.filter(galleryId: first) == .all)
        #expect(defaults.string(forKey: VerdictFilter.storageKey(galleryId: first)) == nil)

        defaults.set("favourites", forKey: VerdictFilter.storageKey(galleryId: second))
        #expect(store.filter(galleryId: second) == .all, "a value from a newer version falls back to « Toutes »")
    }
}

/// The real `ManualSorter` on an in-memory catalogue, with the gallery view's refresh done by hand.
@MainActor
private struct SortingFixture {
    /// Kept here: a context does not keep its container alive.
    let container: ModelContainer
    let context: ModelContext
    let photos: [Photo]
    let browser = GalleryBrowser()
    let undoManager = UndoManager()
    let sorter: ManualSorter

    init(aiVerdicts: [CullingVerdict], burst: (number: Int, best: Int)? = nil) throws {
        container = try makeInMemoryContainer()
        context = ModelContext(container)
        var photos: [Photo] = []
        for (index, verdict) in aiVerdicts.enumerated() {
            let photo = Photo(draft: PhotoDraft(
                file: PhotoFile(url: URL(filePath: "/tmp/\(index).ARW"), relativePath: "\(index).ARW", fileSize: 1_000),
                metadata: PhotoMetadata(captureDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)), pixelWidth: 4000, pixelHeight: 6000),
                importedAt: Date()
            ))
            context.insert(photo)
            photo.cullingVerdictRaw = verdict.rawValue
            if let burst {
                photo.burstNumber = burst.number
                photo.isBestOfBurst = index == burst.best
            }
            photos.append(photo)
        }
        try context.save()
        self.photos = photos
        // Each change is its own undo group (see `ManualSortingTests.Fixture`).
        undoManager.groupsByEvent = false
        browser.setPhotos(photos.map(\.burstInput))
        sorter = ManualSorter(browser: browser, context: context, undoManager: undoManager)
    }

    /// What the gallery view does when `@Query` gives the saved photos again.
    func refresh() {
        browser.setPhotos(photos.map(\.burstInput))
    }

    /// One key press on the selection (moving on to the next photo), as one undo step, then the refresh.
    /// Always inside an undo group: with `groupsByEvent` off, AppKit refuses an undo registered
    /// outside one, and in the app hosting the tests that shows up as a crash or a silent hang.
    func press(_ command: SortingCommand) {
        undoManager.beginUndoGrouping()
        sorter.applyToSelection(command, advance: true)
        undoManager.endUndoGrouping()
        refresh()
    }

    /// The B key on the selection, as one undo step, then the refresh.
    func pressB() -> Bool {
        undoManager.beginUndoGrouping()
        let handled = sorter.chooseSelectedBurstCover()
        undoManager.endUndoGrouping()
        refresh()
        return handled
    }
}
