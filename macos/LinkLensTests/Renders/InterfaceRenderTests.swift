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

    /// The welcome screen in a small window: it scrolls instead of growing the window.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func emptyLibrary(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary.empty()
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

    // MARK: - Batch 5: welcome, drop, card import window

    /// First launch: no gallery, the welcome screen of the mockup (1440 × 900 like Accueil.dc.html).
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func welcome(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary.empty()
        try await WindowRenderer.render(library.mainWindow(selecting: nil), named: "accueil", size: CGSize(width: 1440, height: 900), appearance: appearance)
    }

    /// A folder dragged over the welcome screen: the drop zone and the window light up.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func welcomeDuringDrop(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary.empty()
        try await WindowRenderer.render(
            library.mainWindow(selecting: nil, isDropTargeted: true),
            named: "accueil-glisser", size: CGSize(width: 1440, height: 900), appearance: appearance
        )
    }

    /// A folder dragged over a gallery: the frame and the message in the middle.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func gridDuringDrop(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        try await withInspector(shown: false) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session, isDropTargeted: true),
                named: "grille-glisser", size: CGSize(width: 1280, height: 800), appearance: appearance
            )
        }
    }

    /// The card of the mockup (10 photos with real thumbnails, 1 video), the session name typed.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func cardImportForm(appearance: WindowRenderer.Appearance) async throws {
        try await renderCardImport(named: "import-carte", appearance: appearance) { controller, _ in
            controller.sessionName = "Mariage Julie & Tom"
            let pictures = URL(filePath: realHomeDirectory(), directoryHint: .isDirectory).appending(path: "Pictures/LinkLens")
            controller.showForRenders(controller.stage, destination: ImportDestination(url: pictures, bookmark: Data()))
        }
    }

    /// During the copy: 6 files of 11 copied and checked.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func cardImportProgress(appearance: WindowRenderer.Appearance) async throws {
        try await renderCardImport(named: "import-carte-progression", appearance: appearance) { controller, card in
            let bytes = card.totalBytes
            controller.showForRenders(.importing(card), progress: CardImportProgress(
                phase: .copying, completedFiles: 6, totalFiles: card.files.count,
                completedBytes: bytes * 6 / 11, totalBytes: bytes, currentFile: "DSC04320.JPG"
            ))
        }
    }

    /// A real import of the fake card into a temporary location: « Vous pouvez formater la carte ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func cardImportFinished(appearance: WindowRenderer.Appearance) async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "LinkLensRenderImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await renderCardImport(named: "import-carte-terminee", appearance: appearance) { controller, _ in
            controller.sessionName = "Mariage Julie & Tom"
            controller.showForRenders(controller.stage, destination: ImportDestination(url: destination, bookmark: try FolderBookmark.createReadWrite(for: destination)))
            controller.startImport()
            await controller.waitUntilFinished()
            guard case .finished(let report) = controller.stage else {
                Issue.record("Import not finished: \(controller.stage), \(controller.errorMessage ?? "")")
                return
            }
            #expect(report.canFormatCard)
        }
    }

    /// One copy differs from the original: « Ne formatez pas la carte ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func cardImportIncomplete(appearance: WindowRenderer.Appearance) async throws {
        try await renderCardImport(named: "import-carte-incomplet", appearance: appearance) { controller, card in
            let folder = URL(filePath: "/tmp/2026/2026-09-20 Mariage Julie & Tom", directoryHint: .isDirectory)
            let copied = card.files.dropFirst().map { file in
                CopiedFile(sourcePath: file.relativePath, destination: folder.appending(path: file.url.lastPathComponent), sha256: "")
            }
            controller.showForRenders(.finished(CardImportReport(
                cardName: card.name, sessionFolder: folder, sessionPath: "2026/2026-09-20 Mariage Julie & Tom",
                copiedFiles: Array(copied),
                failures: [CardImportFailure(relativePath: card.files[0].relativePath, reason: .mismatch)],
                notImported: [], galleryId: nil, indexingError: nil
            )))
        }
    }

    /// A fake card in a temporary folder (10 real thumbnails as photos, an empty MP4), read by the real
    /// scanner after a « drop »; `configure` puts the window in the state to render.
    private func renderCardImport(
        named name: String,
        appearance: WindowRenderer.Appearance,
        configure: (CardImportController, CardContents) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "LinkLensRenderCard-\(UUID().uuidString)/SDTEST", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let photos = root.appending(path: "DCIM/100MSDCF", directoryHint: .isDirectory)
        let clips = root.appending(path: "PRIVATE/M4ROOT/CLIP", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        // 20 Sept. 2026, 14:40 in Paris: the thumbnails have no EXIF date, the file date is used.
        let taken = Date(timeIntervalSince1970: 1_789_908_057)
        for (index, number) in RenderLibrary.fixtureNumbers.prefix(10).enumerated() {
            let file = photos.appending(path: String(format: "DSC%05d.JPG", number))
            try FileManager.default.copyItem(at: try RenderLibrary.fixtureThumbnailURL(number), to: file)
            try FileManager.default.setAttributes([.modificationDate: taken.addingTimeInterval(Double(index) * 40)], ofItemAtPath: file.path)
        }
        let clip = clips.appending(path: "C0001.MP4")
        try Data(count: 4_096).write(to: clip)
        try FileManager.default.setAttributes([.modificationDate: taken.addingTimeInterval(600)], ofItemAtPath: clip.path)

        let library = try RenderLibrary()
        let controller = library.makeCardImportController()
        controller.importDroppedCard(root)
        await controller.waitUntilFinished()
        guard case .ready(let card) = controller.stage else {
            Issue.record("Card not read: \(controller.errorMessage ?? "")")
            return
        }
        try await configure(controller, card)
        try await withInspector(shown: false) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session, cardImport: controller),
                named: name, size: CGSize(width: 1440, height: 900), appearance: appearance, settle: .seconds(3)
            )
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

    // MARK: - Review of the « À revoir » photos

    /// Burst 4 (DSC04307–04313): the best photo DSC04311 (kept by the user) next to DSC04312, the whole
    /// burst below. Each photo of a burst has its best photo's thumbnail (the 14 real ones only).
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func reviewBurst(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let compared = try #require(library.session.photos.first { $0.relativePath == "DSC04312.ARW" })
        try await renderReview(named: "revue-rafale", library: library, appearance: appearance) { session in
            session.reveal(compared.id)
        }
    }

    /// A photo on its own (DSC04317, made « À revoir » for the render: subject a little blurry, cut on the right).
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func reviewSinglePhoto(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let photo = try #require(library.session.photos.first { $0.relativePath == "DSC04317.ARW" })
        photo.cullingVerdictRaw = "review"
        photo.cullingReasonsData = try JSONEncoder().encode([
            CullingReason(kind: .slightlyBlurry, verdict: .review, value: 34, threshold: 45, onSubject: true),
            CullingReason(kind: .subjectCut, verdict: .review, value: 0.01, side: .right),
        ])
        try library.container.mainContext.save()
        try await renderReview(named: "revue-photo-seule", library: library, appearance: appearance) { session in
            session.reveal(photo.id)
        }
    }

    /// The end: half the photos to review kept, the others rejected but two.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func reviewSummary(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        try await renderReview(named: "revue-bilan", library: library, appearance: appearance) { session in
            let ids = session.stops.flatMap(\.reviewIds)
            for (index, id) in ids.enumerated() where index >= 2 {
                library.session.photos.first { $0.id == id }?.userVerdictRaw = index % 2 == 0 ? "keep" : "reject"
            }
            try library.container.mainContext.save()
            session.goToStop(session.stops.count)
        }
    }

    /// F9: the wedding gallery, its disk unplugged: cached thumbnails, « zoom 100 % indisponible ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func reviewWithDiskUnplugged(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.availabilityMonitor.refresh()
        await library.availabilityMonitor.waitUntilIdle()
        try #require(!library.availabilityMonitor.availability(of: library.wedding.id).canUseOriginals)
        try await renderReview(named: "revue-disque-absent", library: library, gallery: library.wedding, appearance: appearance) { _ in }
    }

    /// The same at 1440 points, inspector closed: the whole title « Reprendre la revue (reste N) ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func reviewResumeWide(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let session = library.reviewController.open(galleryId: library.session.id, photos: Self.reviewInputs(of: library.session))
        session.skip()
        library.reviewController.close(galleryId: library.session.id)
        try await withInspector(shown: false) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "revue-reprendre-large",
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            )
        }
    }

    /// The grid after Escape half-way, at the app's default width with the inspector open (the narrowest
    /// case): « Reprendre (N) » next to the filters, the size slider gives way to it.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func reviewResume(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let session = library.reviewController.open(galleryId: library.session.id, photos: Self.reviewInputs(of: library.session))
        session.skip()
        session.skip()
        library.reviewController.close(galleryId: library.session.id)
        try await withInspector(shown: true) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "revue-reprendre",
                size: CGSize(width: 1280, height: 800),
                appearance: appearance
            )
        }
    }

    /// Opens the review of `gallery` (the session of September 20 by default), lets `prepare` move it, renders.
    private func renderReview(
        named name: String,
        library: RenderLibrary,
        gallery: Gallery? = nil,
        appearance: WindowRenderer.Appearance,
        prepare: (ReviewSession) throws -> Void
    ) async throws {
        let gallery = gallery ?? library.session
        let session = library.reviewController.open(galleryId: gallery.id, photos: Self.reviewInputs(of: gallery))
        try prepare(session)
        try await withInspector(shown: false) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: gallery),
                named: name,
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            )
        }
    }

    /// The photos as `GalleryDetailView` gives them to the review: by date, then by name.
    private static func reviewInputs(of gallery: Gallery) -> [BurstStacks.Input] {
        gallery.photos
            .sorted { ($0.captureDate ?? .distantPast, $0.relativePath) < ($1.captureDate ?? .distantPast, $1.relativePath) }
            .map(\.burstInput)
    }

    // MARK: - Deleting a gallery

    /// The confirmation window over the session of September 20, the box unticked (as it opens).
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func deletionWindow(appearance: WindowRenderer.Appearance) async throws {
        try await renderDeletion(named: "suppression-galerie", appearance: appearance, alsoTrashFolder: false)
    }

    /// The same, « Mettre aussi le dossier à la corbeille » ticked.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func deletionWindowTicked(appearance: WindowRenderer.Appearance) async throws {
        try await renderDeletion(named: "suppression-galerie-cochee", appearance: appearance, alsoTrashFolder: true)
    }

    /// The wedding gallery, its disk unplugged: the box is greyed out and says why.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func deletionWindowGreyedOut(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.deletionController.showForRenders(
            request: GalleryDeletionRequest(library.wedding),
            folderCheck: FolderTrashCheck(folderPath: library.wedding.folderPath, outcome: .blocked(.diskDisconnected(volumeName: "Photos 2TB")))
        )
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.wedding),
            named: "suppression-galerie-grisee",
            size: CGSize(width: 1280, height: 800),
            appearance: appearance
        )
    }

    /// Right after a deletion with the folder: the forest gallery is shown, the banner offers « Annuler ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func deletionBanner(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.deletionController.showForRenders(request: nil, folderCheck: nil, banner: GalleryDeletionBanner(
            galleryId: UUID(), galleryName: "Mariage Julie & Tom", kind: .deleted(folderTrashed: true)
        ))
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "suppression-bandeau",
            size: CGSize(width: 1280, height: 800),
            appearance: appearance
        )
    }

    /// After « Annuler », when the folder could not be put back (its place was taken).
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func deletionBannerRestored(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.deletionController.showForRenders(request: nil, folderCheck: nil, banner: GalleryDeletionBanner(
            galleryId: library.wedding.id, galleryName: library.wedding.name, kind: .restored(problem: FolderRestoreProblem.placeTaken.message)
        ))
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.wedding),
            named: "suppression-bandeau-retour",
            size: CGSize(width: 1280, height: 800),
            appearance: appearance
        )
    }

    /// The session of September 20 (~/Downloads/photos, 52 RAW files, about 1,2 Go). The folder's listing
    /// is made up: nothing reads or touches the real folder.
    private func renderDeletion(named name: String, appearance: WindowRenderer.Appearance, alsoTrashFolder: Bool) async throws {
        let library = try RenderLibrary()
        let contents = FolderContents(entries: (0..<52).map {
            FolderContents.Entry(relativePath: String(format: "DSC0%04d.ARW", 4297 + $0), size: 23_100_000, modifiedAt: nil)
        })
        library.deletionController.showForRenders(
            request: GalleryDeletionRequest(library.session),
            folderCheck: FolderTrashCheck(folderPath: library.session.folderPath, outcome: .allowed(contents)),
            alsoTrashFolder: alsoTrashFolder
        )
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: name,
            size: CGSize(width: 1280, height: 800),
            appearance: appearance
        )
    }

    // MARK: - Deleting photos (batch 3)

    /// Six photos selected with → × 4 then ⇧→ × 5: rings on each, the inspector's summary.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func photosMultiSelection(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        try await withInspectorShown {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "photos-selection-multiple",
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            ) { window in
                for _ in 0..<4 { WindowRenderer.pressRightArrow(in: window) }
                for _ in 0..<5 { WindowRenderer.pressRightArrow(in: window, modifiers: .shift) }
            }
        }
    }

    /// « Mettre 6 photos à la corbeille ? » over the grid: thumbnails, size, what happens, the buttons.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func photosDeletionWindow(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let photos = Self.sessionPhotos(library).filter { library.cache.contains($0.id) }.prefix(6)
        let request = PhotoDeletionRequest(galleryId: library.session.id, galleryName: library.session.name, kind: .selection, items: photos.map(\.trashItem))
        library.photoDeletion.showForRenders(request: request, stamps: Self.stamps(of: request))
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "photos-suppression",
            size: CGSize(width: 1280, height: 860),
            appearance: appearance
        )
    }

    /// The 26 rejected photos, from the « Rejeter » filter (its button behind the window).
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func photosDeletionRejected(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let filters = VerdictFilterStore()
        filters.setFilter(.reject, galleryId: library.session.id)
        defer { filters.setFilter(.all, galleryId: library.session.id) }
        let rejected = Self.sessionPhotos(library).filter { $0.verdict == .reject }
        // The photos with a real thumbnail first, so the window shows some.
        let ordered = rejected.filter { library.cache.contains($0.id) } + rejected.filter { !library.cache.contains($0.id) }
        let request = PhotoDeletionRequest(galleryId: library.session.id, galleryName: library.session.name, kind: .rejected, items: ordered.map(\.trashItem))
        library.photoDeletion.showForRenders(request: request, stamps: Self.stamps(of: request))
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "photos-suppression-rejetees",
            size: CGSize(width: 1280, height: 900),
            appearance: appearance
        )
    }

    /// The « Rejeter » filter on its own: « Mettre les 26 photos rejetées à la corbeille… » next to the filters.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func photosRejectedFilter(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let filters = VerdictFilterStore()
        filters.setFilter(.reject, galleryId: library.session.id)
        defer { filters.setFilter(.all, galleryId: library.session.id) }
        try await withInspector(shown: false) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "photos-filtre-rejeter",
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            )
        }
    }

    /// An exFAT disk without a trash: nothing moved, the files listed, « Retirer seulement de LinkLens ».
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func photosTrashRefused(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let refusal = CocoaError(.fileWriteVolumeReadOnly).localizedDescription
        let skipped = Self.sessionPhotos(library).filter { $0.verdict == .reject }.prefix(8).map {
            SkippedPhoto(item: $0.trashItem, reason: .trashRefused(refusal))
        }
        library.photoDeletion.showForRenders(report: PhotoDeletionReport(
            galleryId: library.session.id, galleryName: library.session.name, trashedCount: 0, skipped: Array(skipped)
        ))
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "photos-corbeille-refusee",
            size: CGSize(width: 1280, height: 860),
            appearance: appearance
        )
    }

    /// Right after: « 26 photos mises à la corbeille · Annuler » over the grid.
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func photosDeletionBanner(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        library.photoDeletion.showForRenders(banner: PhotoDeletionBanner(recordId: UUID(), kind: .trashed(count: 26, keptInPlace: 0)))
        try await WindowRenderer.render(
            library.mainWindow(selecting: library.session),
            named: "photos-bandeau",
            size: CGSize(width: 1280, height: 800),
            appearance: appearance
        )
    }

    /// The review's summary with « Mettre les 26 photos rejetées à la corbeille… », inspector asked for
    /// but hidden (nothing to inspect there).
    @Test(arguments: WindowRenderer.Appearance.allCases)
    func reviewSummaryWithTrash(appearance: WindowRenderer.Appearance) async throws {
        let library = try RenderLibrary()
        let session = library.reviewController.open(galleryId: library.session.id, photos: Self.reviewInputs(of: library.session))
        session.goToStop(session.stops.count)
        try await withInspector(shown: true) {
            try await WindowRenderer.render(
                library.mainWindow(selecting: library.session),
                named: "revue-bilan-corbeille",
                size: CGSize(width: 1440, height: 900),
                appearance: appearance
            )
        }
    }

    /// Every file « looked at » (nothing is read on disk): the window then says none is missing.
    private static func stamps(of request: PhotoDeletionRequest) -> [UUID: FileStamp] {
        Dictionary(uniqueKeysWithValues: request.items.map { ($0.photoId, FileStamp(size: $0.fileSize, modifiedAt: nil)) })
    }

    /// The session's photos in display order (date, then name).
    private static func sessionPhotos(_ library: RenderLibrary) -> [Photo] {
        library.session.photos.sorted { ($0.captureDate ?? .distantPast, $0.relativePath) < ($1.captureDate ?? .distantPast, $1.relativePath) }
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
