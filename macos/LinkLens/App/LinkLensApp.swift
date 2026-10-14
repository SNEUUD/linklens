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

    init() {
        do {
            container = try ModelContainer(for: Gallery.self, Photo.self)
        } catch {
            fatalError("Impossible d'ouvrir la base SwiftData : \(error)")
        }
        let store = LibraryStore(modelContainer: container)
        let culling = CullingController(store: store)
        _cullingController = State(initialValue: culling)
        _importController = State(initialValue: ImportController(store: store) { galleryId in
            culling.cull(galleryId: galleryId)
        })
        // Galleries never sorted (indexed before F3, or sorting interrupted) are sorted at launch.
        // Not while the unit tests run inside the app: they must not touch the real catalogue.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            culling.cullPendingGalleries()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(importController)
                .environment(cullingController)
                .environment(exportController)
        }
        // Wide enough at first launch for every column of the photo table without scrolling sideways.
        .defaultSize(width: 1280, height: 760)
        .modelContainer(container)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Ajouter un dossier…", action: importController.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(importController.isIndexing)
            }
        }
    }
}
