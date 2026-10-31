import AppKit
import SwiftData
import SwiftUI

/// App entry point. `@main` tells Swift where the program starts (like the root `index.tsx`).
@main
struct LinkLensApp: App {
    /// The SwiftData database, stored in the app's sandbox container.
    private let container: ModelContainer
    @State private var importController: ImportController
    @State private var cullingController: CullingController
    @State private var exportController: ExportController
    @State private var cardImportController: CardImportController
    @State private var cardMonitor: CardMonitor
    @State private var duplicatesController: DuplicatesController
    @State private var availabilityMonitor: GalleryAvailabilityMonitor
    @State private var detailsController: DetailsBackfillController
    @State private var deletionController: GalleryDeletionController
    @State private var photoDeletion: PhotoDeletionController
    /// The reviews of the « À revoir » photos, kept while the app runs (« Reprendre la revue »).
    @State private var reviewController = ReviewController()

    init() {
        do {
            container = try ModelContainer(for: Gallery.self, Photo.self)
        } catch {
            fatalError("Impossible d'ouvrir la base SwiftData : \(error)")
        }
        let store = LibraryStore(modelContainer: container)
        let culling = CullingController(store: store)
        _cullingController = State(initialValue: culling)
        let folderImport = ImportController(store: store) { galleryId in
            culling.cull(galleryId: galleryId)
        }
        _importController = State(initialValue: folderImport)
        // `_name = State(initialValue:)` sets a `@State` property from `init`, before the view exists.
        let cardImport = CardImportController(importer: CardImporter(store: store)) { galleryId, sortNow in
            folderImport.selectedGalleryId = galleryId
            // Not sorted now: it will be at the next launch, or with « Trier » in the toolbar.
            if sortNow { culling.cull(galleryId: galleryId) }
        }
        _cardImportController = State(initialValue: cardImport)
        // F9: which galleries have their disk plugged in. When a disk comes back, the galleries that
        // could not be sorted while it was away are sorted now (only those never sorted).
        let availability = GalleryAvailabilityMonitor(store: store)
        // Inspector details of the photos sorted before batch 3, read again in the background. Not for a
        // gallery whose disk is unplugged, nor one being sorted (the sorting stores them itself).
        let details = DetailsBackfillController(store: store)
        details.canRead = { galleryId in
            availability.availability(of: galleryId).canUseOriginals && !culling.isBusy(galleryId: galleryId)
        }
        _detailsController = State(initialValue: details)
        availability.onGalleriesBecameAvailable = { _ in
            culling.cullPendingGalleries()
            details.fillPendingGalleries()
        }
        _availabilityMonitor = State(initialValue: availability)
        let duplicates = DuplicatesController(store: store)
        duplicates.galleryAvailability = { availability.availability(of: $0) }
        _duplicatesController = State(initialValue: duplicates)
        let export = ExportController()
        _exportController = State(initialValue: export)
        // Deleting a gallery: not while something reads or writes it, nor during the duplicate search
        // (which goes through every gallery). The import location is never put in the trash.
        let deletion = GalleryDeletionController(store: store)
        deletion.galleryAvailability = { availability.availability(of: $0) }
        // Photos put in the trash from a gallery: the same rules, for the photos of one gallery.
        let photoDeletion = PhotoDeletionController(store: store)
        photoDeletion.galleryAvailability = { availability.availability(of: $0) }
        photoDeletion.isBusy = { galleryId in
            folderImport.progress?.galleryId == galleryId || culling.isBusy(galleryId: galleryId)
                || details.runningGalleryId == galleryId || export.progress?.galleryId == galleryId
                || duplicates.isScanning || duplicates.isMovingFiles
        }
        _photoDeletion = State(initialValue: photoDeletion)
        deletion.isBusy = { galleryId in
            folderImport.progress?.galleryId == galleryId || culling.isBusy(galleryId: galleryId)
                || details.runningGalleryId == galleryId || export.progress?.galleryId == galleryId
                || duplicates.isScanning || duplicates.isMovingFiles || photoDeletion.progress?.galleryId == galleryId
        }
        deletion.protectedPaths = {
            let destination = cardImport.defaultDestination.map { FolderBookmark.canonicalPath(of: $0.url) }
            return FolderTrashRules.protectedPaths(home: realHomeDirectory(), extra: destination.map { [$0] } ?? [])
        }
        deletion.selectedGalleryId = { folderImport.selectedGalleryId }
        deletion.selectGallery = { folderImport.selectedGalleryId = $0 }
        _deletionController = State(initialValue: deletion)
        let monitor = CardMonitor()
        _cardMonitor = State(initialValue: monitor)
        // Galleries never sorted (indexed before F3, or sorting interrupted) are sorted at launch, and
        // inserted cards are watched. Not while the unit tests run inside the app: they must not touch
        // the real catalogue.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            culling.cullPendingGalleries()
            details.fillPendingGalleries()
            monitor.start()
            availability.start()
            // Thumbnails of galleries and photos deleted before the last quit (or a crash): no undo is
            // possible now. The queue holds both (photo deletions under their own id).
            Task { await deletion.purgeLeftovers() }
            // When the app quits, every undo ends: the thumbnails of deleted galleries and photos go.
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                // The notification comes on the main thread (`queue: .main`): `assumeIsolated` tells Swift so.
                MainActor.assumeIsolated {
                    deletion.finishAllNow()
                    photoDeletion.finishAllNow()
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(importController)
                .environment(cullingController)
                .environment(exportController)
                .environment(cardImportController)
                .environment(cardMonitor)
                .environment(duplicatesController)
                .environment(availabilityMonitor)
                .environment(detailsController)
                .environment(deletionController)
                .environment(photoDeletion)
                .environment(reviewController)
        }
        // Wide enough at first launch for every column of the photo table without scrolling sideways.
        .defaultSize(width: 1280, height: 760)
        .modelContainer(container)
        .commands {
            CommandGroup(after: .newItem) {
                // The menu bar is outside the window: the controllers are passed to it explicitly.
                ImportMenuItems(cardTitle: "Importer une carte SD…", folderTitle: "Ajouter un dossier…")
                    .environment(importController)
                    .environment(cardImportController)
            }
            // Filters and thumbnail size, at the top of the system's « Présentation » menu.
            CommandGroup(before: .toolbar) {
                PresentationMenuCommands()
            }
            // `CommandMenu` adds a menu of its own to the menu bar, after « Présentation ».
            CommandMenu("Galerie") {
                GalleryMenuCommands()
            }
        }
    }
}
