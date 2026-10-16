import AppKit
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

    // MARK: - Batch 3: inspector

    /// DSC04311 selected (→ × 4), as proposed by the AI: real thumbnail, real subject box and measurements.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func inspector(appearance: WindowRenderer.Appearance) async throws {
        try await renderInspector(named: "inspecteur", appearance: appearance) { photo in
            photo.userVerdictRaw = nil
        }
    }

    /// The same photo put in « À revoir » by the user: « Votre choix · l'IA proposait Garder ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func inspectorWithUserChoice(appearance: WindowRenderer.Appearance) async throws {
        try await renderInspector(named: "inspecteur-votre-choix", appearance: appearance) { photo in
            photo.userVerdictRaw = "review"
        }
    }

    /// Nothing selected yet.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func inspectorEmpty(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        try await withInspectorShown {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "inspecteur-vide",
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            )
        }
    }

    /// The pill no longer covers the last row: the last photo selected (→ × 13), the grid scrolled to the end.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func gridEndAbovePill(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.exportController.showProgressForRenders(
            ExportProgress(galleryId: library.session.id, preset: .webJPEG, completed: 8, total: 26), startedAt: .now
        )
        try await withInspectorShown {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "grille-fin-pilule",
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            ) { window in
                for _ in 0..<13 { WindowRenderer.pressRightArrow(in: window) }
            }
        }
    }

    /// The list with the inspector open, at the app's default window size: every column must still fit.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func tableWithInspector(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let defaults = UserDefaults.standard
        let previousLayout = defaults.object(forKey: "galleryLayout")
        defaults.set(GalleryLayout.table.rawValue, forKey: "galleryLayout")
        defer { defaults.set(previousLayout, forKey: "galleryLayout") }
        try await withInspectorShown {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "tableau-inspecteur",
                size: CGSize(width: 1280, height: 760),
                appearance: appearance
            ) { window in
                for _ in 0..<4 { WindowRenderer.press(keyCode: 125, characters: String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)), in: window) }
            }
        }
    }

    // MARK: - Batch 4: full-window viewer

    /// DSC04311 in its open burst (→ × 4, S, space), as proposed by the AI, the subject box shown.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func viewer(appearance: WindowRenderer.Appearance) async throws {
        try await renderViewer(named: "visualiseur", appearance: appearance) { photo in
            photo.userVerdictRaw = nil
        }
    }

    /// The same photo put in « À revoir » by the user: « Votre choix · l'IA proposait Garder ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func viewerWithUserChoice(appearance: WindowRenderer.Appearance) async throws {
        try await renderViewer(named: "visualiseur-votre-choix", appearance: appearance) { photo in
            photo.userVerdictRaw = "review"
        }
    }

    /// The viewer with the inspector open (⌥⌘I), at the app's default window size.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func viewerWithInspector(appearance: WindowRenderer.Appearance) async throws {
        try await renderViewer(named: "visualiseur-inspecteur", appearance: appearance, size: CGSize(width: 1280, height: 760), inspector: true) { photo in
            photo.userVerdictRaw = nil
        }
    }

    /// Z: DSC04311 at 100 %, framed on its subject. The render has no original file: the thumbnail is
    /// enlarged instead (blurry) and « Lecture de la pleine définition… » stays.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func viewerZoomed(appearance: WindowRenderer.Appearance) async throws {
        try await renderViewer(named: "visualiseur-zoom", appearance: appearance, extraKeys: [(6, "z")]) { photo in
            photo.userVerdictRaw = nil
        }
    }

    /// F9: the wedding gallery with its disk unplugged, the first photo in the viewer: « Aperçu réduit ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func viewerWithDiskUnplugged(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.availabilityMonitor.refresh()
        await library.availabilityMonitor.waitUntilIdle()
        try #require(!library.availabilityMonitor.availability(of: library.wedding.id).canUseOriginals)
        try await withInspector(shown: false) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.wedding),
                named: "visualiseur-apercu-reduit",
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            ) { window in
                WindowRenderer.pressRightArrow(in: window)
                WindowRenderer.press(keyCode: 49, characters: " ", in: window)
            }
        }
    }

    private func renderViewer(
        named name: String,
        appearance: WindowRenderer.Appearance,
        size: CGSize = CGSize(width: 1440, height: 900),
        inspector: Bool = false,
        extraKeys: [(keyCode: UInt16, characters: String)] = [],
        configure: (Photo) -> Void
    ) async throws {
        let library = try RenderLibrary()
        let photo = try #require(library.session.photos.first { $0.relativePath == "DSC04311.ARW" })
        configure(photo)
        try library.container.mainContext.save()
        let defaults = UserDefaults.standard
        let previousSubject = defaults.object(forKey: PhotoViewer.showsSubjectKey)
        defaults.set(true, forKey: PhotoViewer.showsSubjectKey)
        defer { defaults.set(previousSubject, forKey: PhotoViewer.showsSubjectKey) }
        try await withInspector(shown: inspector) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: name,
                size: size,
                appearance: appearance
            ) { window in
                // → × 4: the stack of burst 4 (DSC04311); S opens it; space opens the viewer.
                for _ in 0..<4 { WindowRenderer.pressRightArrow(in: window) }
                WindowRenderer.press(keyCode: 1, characters: "s", in: window)
                WindowRenderer.press(keyCode: 49, characters: " ", in: window)
                if !extraKeys.isEmpty {
                    try await Task.sleep(for: .seconds(1))
                    for key in extraKeys { WindowRenderer.press(keyCode: key.keyCode, characters: key.characters, in: window) }
                }
            }
        }
    }

    private func renderInspector(
        named name: String,
        appearance: WindowRenderer.Appearance,
        configure: (Photo) -> Void
    ) async throws {
        let library = try RenderLibrary()
        let photo = try #require(library.session.photos.first { $0.relativePath == "DSC04311.ARW" })
        configure(photo)
        try library.container.mainContext.save()
        try await withInspectorShown {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: name,
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            ) { window in
                for _ in 0..<4 { WindowRenderer.pressRightArrow(in: window) }
            }
        }
    }

    /// The inspector is remembered in the user defaults (`@AppStorage`): shown for the render, then the
    /// previous value is put back.
    private func withInspectorShown(_ body: () async throws -> Void) async throws {
        try await withInspector(shown: true, body)
    }

    private func withInspector(shown: Bool, _ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "isInspectorShown")
        defaults.set(shown, forKey: "isInspectorShown")
        defer { defaults.set(previous, forKey: "isInspectorShown") }
        try await body()
    }
}
