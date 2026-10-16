import Foundation
import Testing
@testable import LinkLens

/// F4: bursts shown as stacks of their best photo, opened and closed by the user.
struct BurstStacksTests {
    /// Photos described by their burst: nil = single photo, `(2, true)` = best photo of burst 2.
    private func photos(_ bursts: [(Int, Bool)?]) -> [BurstStacks.Input] {
        bursts.map { burst in
            BurstStacks.Input(id: UUID(), burstNumber: burst?.0, isBestOfBurst: burst?.1 ?? false)
        }
    }

    @Test func collapsedBurstShowsOnlyItsBestPhoto() {
        // single, burst 1 (3 photos, the 2nd is the best), single.
        let input = photos([nil, (1, false), (1, true), (1, false), nil])

        let entries = BurstStacks.entries(for: input, expanded: [])

        #expect(entries.map(\.photoIndex) == [0, 2, 4])
        #expect(entries[0].burst == nil)
        #expect(entries[1].burst == BurstPlacement(number: 1, count: 3, isExpanded: false, isCover: true))
        #expect(entries[2].burst == nil)
    }

    @Test func expandedBurstShowsEveryPhotoInOrder() {
        let input = photos([(1, false), (1, false), (1, true), nil, (2, true), (2, false)])

        let entries = BurstStacks.entries(for: input, expanded: [1])

        #expect(entries.map(\.photoIndex) == [0, 1, 2, 3, 4])
        #expect(entries.map(\.photoId) == [0, 1, 2, 3, 4].map { input[$0].id })
        #expect(entries[0...2].allSatisfy { $0.burst?.isExpanded == true && $0.burst?.count == 3 })
        #expect(entries[0...2].map { $0.burst?.isCover } == [false, false, true])
        #expect(entries[4].burst == BurstPlacement(number: 2, count: 2, isExpanded: false, isCover: true))
    }

    @Test func burstWithoutBestPhotoUsesItsFirstPhoto() {
        let input = photos([(1, false), (1, false)])

        let entries = BurstStacks.entries(for: input, expanded: [])

        #expect(entries.map(\.photoIndex) == [0])
        #expect(entries[0].burst?.isCover == true)
    }

    @Test func burstStaysOneBlockEvenWhenAPhotoIsSortedBetweenItsMembers() {
        // E.g. a photo without date sorted in the middle of a burst.
        let input = photos([(1, false), nil, (1, true)])

        #expect(BurstStacks.entries(for: input, expanded: []).map(\.photoIndex) == [2, 1])
        #expect(BurstStacks.entries(for: input, expanded: [1]).map(\.photoIndex) == [0, 2, 1])
    }

    @Test func galleryWithoutBurstsIsUnchanged() {
        let input = photos([nil, nil, nil])

        #expect(BurstStacks.entries(for: input, expanded: [1]).map(\.photoIndex) == [0, 1, 2])
        #expect(BurstStacks.entries(for: [], expanded: []).isEmpty)
    }
}

/// Bursts in the browser: keyboard navigation and selection follow what is shown.
@MainActor
struct GalleryBrowserBurstTests {
    /// single, burst 1 (best in 2nd position), single.
    private func browser() -> (GalleryBrowser, [UUID]) {
        let ids = (0..<5).map { _ in UUID() }
        let browser = GalleryBrowser()
        browser.setPhotos([
            BurstStacks.Input(id: ids[0]),
            BurstStacks.Input(id: ids[1], burstNumber: 1),
            BurstStacks.Input(id: ids[2], burstNumber: 1, isBestOfBurst: true),
            BurstStacks.Input(id: ids[3], burstNumber: 1),
            BurstStacks.Input(id: ids[4]),
        ])
        browser.columnCount = 10
        return (browser, ids)
    }

    @Test func arrowsSkipThePhotosOfACollapsedBurst() {
        let (browser, ids) = browser()

        #expect(browser.photoIds == [ids[0], ids[2], ids[4]])
        browser.move(.right)
        browser.move(.right)
        #expect(browser.selection == ids[2], "the stack is shown by the best photo")
        browser.move(.right)
        #expect(browser.selection == ids[4])
    }

    @Test func keyOpensAndClosesTheSelectedBurst() {
        let (browser, ids) = browser()
        browser.selection = ids[2]

        #expect(browser.toggleSelectedBurst())
        #expect(browser.photoIds == ids)
        browser.move(.left)
        #expect(browser.selection == ids[1], "the arrows now go through every photo of the burst")

        #expect(browser.toggleSelectedBurst())
        #expect(browser.photoIds == [ids[0], ids[2], ids[4]])
        #expect(browser.selection == ids[2], "a hidden photo hands the selection to its stack")
    }

    @Test func keyDoesNothingOutsideABurst() {
        let (browser, ids) = browser()
        browser.selection = ids[0]

        #expect(!browser.toggleSelectedBurst())
        #expect(browser.expandedBursts.isEmpty)
    }

    @Test func viewerGoesThroughTheShownPhotos() {
        let (browser, ids) = browser()
        browser.toggleBurst(1)
        browser.openViewer(on: ids[0])

        browser.showNeighbour(offset: 1)
        #expect(browser.selection == ids[1])
        browser.toggleBurst(1)
        #expect(browser.selection == ids[2])
        browser.showNeighbour(offset: 1)
        #expect(browser.selection == ids[4])
    }

    @Test func newSortingCollapsesEveryBurst() {
        let (browser, ids) = browser()
        browser.toggleBurst(1)
        browser.selection = ids[3]

        browser.collapseAllBursts()

        #expect(browser.expandedBursts.isEmpty)
        #expect(browser.selection == ids[2])
    }
}

/// F4: the best photo of a burst chosen by hand (B key). The choice belongs to the photo, not to the
/// burst number, which changes on every new sorting.
struct BurstCoverChoiceTests {
    private let earlier = Date(timeIntervalSince1970: 1_790_000_000)
    private let later = Date(timeIntervalSince1970: 1_790_000_100)

    /// One photo: its burst, whether the AI marked it best, and when the user chose it.
    private func photo(_ burst: Int?, ai: Bool = false, chosen: Date? = nil, id: UUID = UUID()) -> BurstStacks.Input {
        BurstStacks.Input(id: id, burstNumber: burst, isBestOfBurst: ai, bestChosenAt: chosen)
    }

    /// Index of the photo shown by each collapsed entry.
    private func covers(_ photos: [BurstStacks.Input]) -> [Int] {
        BurstStacks.entries(for: photos, expanded: []).map(\.photoIndex)
    }

    @Test func theUserChoiceStandsForTheBurstInsteadOfTheAIs() {
        let input = [photo(1, ai: true), photo(1, chosen: earlier), photo(1)]

        let collapsed = BurstStacks.entries(for: input, expanded: [])
        let expanded = BurstStacks.entries(for: input, expanded: [1])

        #expect(collapsed.map(\.photoIndex) == [1])
        #expect(collapsed[0].burst == BurstPlacement(number: 1, count: 3, isExpanded: false, isCover: true, isCoverChosenByUser: true))
        #expect(expanded.map { $0.burst?.isCover } == [false, true, false], "the AI's photo is no longer the cover")
        #expect(expanded.allSatisfy { $0.burst?.isCoverChosenByUser == true }, "every photo of the burst knows it")
    }

    @Test func withoutAChoiceTheAIsBestStaysTheCover() {
        let entries = BurstStacks.entries(for: [photo(1), photo(1, ai: true)], expanded: [])

        #expect(entries.map(\.photoIndex) == [1])
        #expect(entries[0].burst?.isCoverChosenByUser == false)
    }

    @Test func aRenumberedBurstKeepsTheChoice() {
        let ids = (0..<3).map { _ in UUID() }
        let before = [photo(1, ai: true, id: ids[0]), photo(1, chosen: earlier, id: ids[1]), photo(2, ai: true, id: ids[2])]
        // A new sorting: a burst found earlier in the session shifts the numbers.
        let after = [photo(5, ai: true, id: ids[0]), photo(5, chosen: earlier, id: ids[1]), photo(6, ai: true, id: ids[2])]

        #expect(covers(before) == [1, 2])
        #expect(covers(after) == [1, 2])
    }

    @Test func aSplitBurstKeepsTheChoiceInItsPartOnly() {
        // One burst of 4 with the 3rd chosen, then split in two bursts by a new sorting.
        let split = [photo(1, ai: true), photo(1), photo(2, chosen: earlier), photo(2, ai: true)]

        let entries = BurstStacks.entries(for: split, expanded: [])

        #expect(entries.map(\.photoIndex) == [0, 2], "the AI's best for the first part, the user's for the second")
        #expect(entries.map { $0.burst?.isCoverChosenByUser } == [false, true])
    }

    @Test func mergedBurstsKeepTheMostRecentChoice() {
        // Two bursts, each with a choice, merged by a new sorting.
        let merged = [photo(1, ai: true), photo(1, chosen: later), photo(1, chosen: earlier), photo(1)]

        #expect(covers(merged) == [1])
        #expect(covers([photo(1, chosen: earlier), photo(1, chosen: later)]) == [1])
    }

    @Test func equalDatesGiveTheFirstPhoto() {
        #expect(covers([photo(1), photo(1, chosen: earlier), photo(1, chosen: earlier)]) == [1])
    }

    @Test func aChosenPhotoOutsideAnyBurstChangesNothing() {
        let input = [photo(nil, chosen: earlier), photo(1, ai: true), photo(1)]

        let entries = BurstStacks.entries(for: input, expanded: [])

        #expect(entries.map(\.photoIndex) == [0, 1])
        #expect(entries[0].burst == nil)
        #expect(entries[1].burst?.isCoverChosenByUser == false)
    }

    @Test func theStarFollowsTheCover() {
        let ai = BurstPlacement(number: 1, count: 2, isExpanded: true, isCover: true)
        let user = BurstPlacement(number: 1, count: 2, isExpanded: true, isCover: true, isCoverChosenByUser: true)
        let other = BurstPlacement(number: 1, count: 2, isExpanded: true, isCover: false, isCoverChosenByUser: true)

        #expect(ai.showsStar(isBestOfBurst: true))
        #expect(!ai.showsStar(isBestOfBurst: false), "the first photo only stands in when nobody chose")
        #expect(user.showsStar(isBestOfBurst: false))
        #expect(!other.showsStar(isBestOfBurst: true), "the AI's best loses its star to the user's choice")
        #expect(user.starDescription == "Meilleure de la rafale, votre choix")
        #expect(ai.starDescription == "Meilleure de la rafale")
    }
}
