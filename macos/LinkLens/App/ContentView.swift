import SwiftData
import SwiftUI

/// Main window: galleries in the sidebar, photos of the selected gallery on the right.
struct ContentView: View {
    // `@Environment` reads an object provided higher in the tree (like `useContext` in React).
    @Environment(ImportController.self) private var importController
    @Query(sort: \Gallery.createdAt, order: .reverse) private var galleries: [Gallery]

    var body: some View {
        // `@Bindable` gives two-way bindings (`$…`) to the properties of an `@Observable` object.
        @Bindable var importController = importController

        NavigationSplitView {
            GalleryListView(
                galleries: galleries,
                selection: $importController.selectedGalleryId,
                progress: importController.progress,
                onCancel: importController.cancelIndexing
            )
        } detail: {
            if let gallery = galleries.first(where: { $0.id == importController.selectedGalleryId }) {
                GalleryDetailView(gallery: gallery)
                    .id(gallery.id)
            } else if galleries.isEmpty {
                ContentUnavailableView {
                    Label("Aucune galerie", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Importez une carte SD ou un dossier de photos pour commencer.")
                } actions: {
                    Button("Ajouter un dossier…", action: importController.chooseFolder)
                        .disabled(importController.isIndexing)
                }
            } else {
                ContentUnavailableView("Sélectionnez une galerie", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Ajouter un dossier…", systemImage: "folder.badge.plus", action: importController.chooseFolder)
                    .disabled(importController.isIndexing)
                    .help("Indexer un dossier de photos sans le copier")
            }
        }
        .alert(
            "Indexation impossible",
            isPresented: Binding(
                get: { importController.errorMessage != nil },
                set: { if !$0 { importController.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(importController.errorMessage ?? "")
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Gallery.self, Photo.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ContentView()
        .environment(ImportController(container: container))
        .modelContainer(container)
}
