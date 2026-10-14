import SwiftData
import SwiftUI

/// App entry point. `@main` tells Swift where the program starts (like the root `index.tsx`).
@main
struct LinkLensApp: App {
    /// The SwiftData database, stored in the app's sandbox container.
    private let container: ModelContainer
    @State private var importController: ImportController

    init() {
        do {
            container = try ModelContainer(for: Gallery.self, Photo.self)
        } catch {
            fatalError("Impossible d'ouvrir la base SwiftData : \(error)")
        }
        _importController = State(initialValue: ImportController(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(importController)
        }
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
