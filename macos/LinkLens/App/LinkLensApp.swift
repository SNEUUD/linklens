import SwiftData
import SwiftUI

/// App entry point. `@main` tells Swift where the program starts (like the root `index.tsx`).
@main
struct LinkLensApp: App {
    /// The SwiftData database, stored in the app's sandbox container.
    private let container: ModelContainer
    @State private var importController: ImportController
    @State private var cullingController: CullingController
    @State private var exportController = ExportController()
    @State private var cardImportController: CardImportController
    @State private var cardMonitor: CardMonitor
    @State private var duplicatesController: DuplicatesController
    @State private var availabilityMonitor: GalleryAvailabilityMonitor

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
        _cardImportController = State(initialValue: CardImportController(importer: CardImporter(store: store)) { galleryId in
            folderImport.selectedGalleryId = galleryId
            culling.cull(galleryId: galleryId)
        })
        // F9: which galleries have their disk plugged in. When a disk comes back, the galleries that
        // could not be sorted while it was away are sorted now (only those never sorted).
        let availability = GalleryAvailabilityMonitor(store: store)
        availability.onGalleriesBecameAvailable = { _ in culling.cullPendingGalleries() }
        _availabilityMonitor = State(initialValue: availability)
        let duplicates = DuplicatesController(store: store)
        duplicates.galleryAvailability = { availability.availability(of: $0) }
        _duplicatesController = State(initialValue: duplicates)
        let monitor = CardMonitor()
        _cardMonitor = State(initialValue: monitor)
        // Galleries never sorted (indexed before F3, or sorting interrupted) are sorted at launch, and
        // inserted cards are watched. Not while the unit tests run inside the app: they must not touch
        // the real catalogue.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            culling.cullPendingGalleries()
            monitor.start()
            availability.start()
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
        }
        // Wide enough at first launch for every column of the photo table without scrolling sideways.
        .defaultSize(width: 1280, height: 760)
        .modelContainer(container)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Importer une carte…", action: cardImportController.chooseCard)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(cardImportController.isSheetPresented)
                Button("Ajouter un dossier…", action: importController.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(importController.isIndexing)
            }
        }
    }
}
