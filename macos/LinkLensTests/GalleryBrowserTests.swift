import Foundation
import Testing
@testable import LinkLens

/// Selection and keyboard navigation shared by the grid, the table and the viewer.
@MainActor
struct GalleryBrowserTests {
    private func browser(photoCount: Int, columns: Int = 4) -> GalleryBrowser {
        let browser = GalleryBrowser()
        browser.photoIds = (0..<photoCount).map { _ in UUID() }
        browser.columnCount = columns
        return browser
    }

    @Test func arrowsMoveTheSelectionInTheGrid() {
        let browser = browser(photoCount: 10)

        browser.move(.right)
        #expect(browser.selectedIndex == 0, "first arrow selects the first photo")
        browser.move(.right)
        browser.move(.down)
        #expect(browser.selectedIndex == 5)
        browser.move(.up)
        browser.move(.left)
        #expect(browser.selectedIndex == 0)
    }

    @Test func viewerOpensOnlyWithASelection() {
        let browser = browser(photoCount: 3)

        #expect(!browser.openViewer())
        #expect(!browser.isViewerOpen)

        #expect(browser.openViewer(on: browser.photoIds[2]))
        #expect(browser.isViewerOpen)
        #expect(browser.selectedIndex == 2)

        browser.closeViewer()
        #expect(!browser.isViewerOpen)
        #expect(browser.selectedIndex == 2, "the selection stays after closing")
    }

    @Test func viewerNeighboursStopAtBothEnds() {
        let browser = browser(photoCount: 3)
        browser.openViewer(on: browser.photoIds[1])

        browser.showNeighbour(offset: 1)
        browser.showNeighbour(offset: 1)
        #expect(browser.selectedIndex == 2)
        browser.showNeighbour(offset: -1)
        browser.showNeighbour(offset: -1)
        browser.showNeighbour(offset: -1)
        #expect(browser.selectedIndex == 0)
    }

    @Test func selectionOfARemovedPhotoIsIgnored() {
        let browser = browser(photoCount: 3)
        browser.selection = UUID()

        #expect(browser.selectedIndex == nil)
        #expect(!browser.openViewer())
        browser.move(.down)
        #expect(browser.selectedIndex == 0)
    }
}
