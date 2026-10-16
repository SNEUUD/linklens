import Foundation
import SwiftUI
import Testing
@testable import LinkLens

/// PNG renders of the interface, light and dark, to compare with the approved mockup.
///
/// Skipped in the normal test run. To produce them (about 20 s):
///
///     TEST_RUNNER_LINKLENS_RENDERS=1 xcodebuild -project macos/LinkLens.xcodeproj -scheme LinkLens \
///       -destination 'platform=macOS' test -only-testing:LinkLensTests/InterfaceRenderTests
///
/// (`xcodebuild` passes the `TEST_RUNNER_…` variables to the tests without the prefix.)
/// The PNGs land in ~/Library/Containers/fr.chriscrepin.linklens/Data/tmp/LinkLensRenders/,
/// one `<name>-light.png` and `<name>-dark.png` per test; the log prints each path (« Render: … »).
/// To add a screen: one more `@Test` that builds the view from `RenderLibrary` and calls `render`.
@MainActor
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["LINKLENS_RENDERS"] == "1", "Set TEST_RUNNER_LINKLENS_RENDERS=1"),
    .serialized
)
struct InterfaceRenderTests {
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func mainWindow(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "fenetre",
            size: CGSize(width: 1280, height: 800),
            appearance: appearance
        )
    }

    @Test(arguments: WindowRenderer.Appearance.allCases)
    func emptyLibrary(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        for gallery in library.galleries { library.container.mainContext.delete(gallery) }
        try library.container.mainContext.save()
        try await WindowRenderer.render(
            library.mainWindow(selecting: nil),
            named: "fenetre-vide",
            size: CGSize(width: 1080, height: 640),
            appearance: appearance
        )
    }

    /// The sidebar in its other states: indexing, disk unplugged (F9), card inserted.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func sidebarStates(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let wedding = library.wedding.id
        let sidebar = NavigationSplitView {
            LibrarySidebar(
                galleries: library.galleries,
                selection: .constant(library.session.id),
                indexing: IndexingProgress(galleryId: library.forest.id, completed: 9, total: 24),
                availability: { $0 == wedding ? .diskDisconnected(volumeName: "Photos 2TB") : .available },
                cards: [DetectedCard(url: URL(filePath: "/Volumes/SDTEST"), name: "SDTEST")]
            )
        } detail: {
            Color.clear
        }
        try await WindowRenderer.render(
            library.withEnvironment(sidebar),
            named: "barre-laterale-etats",
            size: CGSize(width: 640, height: 720),
            appearance: appearance
        )
    }

    // MARK: - Batch 2: grid, filters, progress pill

    /// « Toutes », the export pill of the mockup (« 8 sur 26 ») and 04311 selected with → → → →.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func gridWithProgress(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.exportController.showProgressForRenders(
            ExportProgress(galleryId: library.session.id, preset: .webJPEG, completed: 8, total: 26), startedAt: .now
        )
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "grille",
            size: CGSize(width: 1440, height: 900),
            appearance: appearance
        ) { window in
            for _ in 0..<4 { WindowRenderer.pressRightArrow(in: window) }
        }
    }

    /// « À revoir »: the 14 photos one by one, bursts unfolded.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func gridFilteredToReview(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        // The filter is remembered in the user defaults under the gallery's id (new at every run).
        let store = VerdictFilterStore()
        store.setFilter(.review, galleryId: library.session.id)
        defer { store.setFilter(.all, galleryId: library.session.id) }
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "grille-a-revoir",
            size: CGSize(width: 1440, height: 900),
            appearance: appearance
        )
    }

    /// F9: the wedding gallery with its disk unplugged, the glass banner above the filters.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func gridWithDiskUnplugged(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.availabilityMonitor.refresh()
        await library.availabilityMonitor.waitUntilIdle()
        try #require(!library.availabilityMonitor.availability(of: library.wedding.id).canUseOriginals)
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.wedding),
            named: "grille-disque-absent",
            size: CGSize(width: 1280, height: 800),
            appearance: appearance
        )
    }
}
