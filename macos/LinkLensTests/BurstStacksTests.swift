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
