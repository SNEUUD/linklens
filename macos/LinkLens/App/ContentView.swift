import SwiftData
import SwiftUI

/// Main window: galleries in the sidebar, photos of the selected gallery on the right.
struct ContentView: View {
    // `@Environment` reads an object provided higher in the tree (like `useContext` in React).
    @Environment(ImportController.self) private var importController
    @Environment(CullingController.self) private var cullingController
    @Environment(CardImportController.self) private var cardImportController
    @Environment(CardMonitor.self) private var cardMonitor
    @Environment(DuplicatesController.self) private var duplicatesController
    @Query(sort: \Gallery.createdAt, order: .reverse) private var galleries: [Gallery]
    @State private var isDuplicatesSheetPresented = false

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
            // `safeAreaInset` pins a view under the list without covering its last rows.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(cardMonitor.cards) { card in
                        DetectedCardBanner(card: card) {
                            if cardImportController.importCard(card) {
                                cardMonitor.dismiss(card)
                            }
                        } onDismiss: {
                            cardMonitor.dismiss(card)
                        }
                    }
                }
            }
        } detail: {
            // `Group` wraps the branches so one modifier (the alert) applies to all of them.
            Group {
                if let gallery = galleries.first(where: { $0.id == importController.selectedGalleryId }) {
                    GalleryDetailView(gallery: gallery)
                        .id(gallery.id)
                } else if galleries.isEmpty {
                    ContentUnavailableView {
                        Label("Aucune galerie", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Importez une carte SD ou un dossier de photos pour commencer.")
                    } actions: {
                        Button("Importer une carte…", action: cardImportController.chooseCard)
                            .disabled(cardImportController.isSheetPresented)
                        Button("Ajouter un dossier…", action: importController.chooseFolder)
                            .disabled(importController.isIndexing)
                    }
                } else {
                    ContentUnavailableView("Sélectionnez une galerie", systemImage: "sidebar.left")
                }
            }
            .alert(
                "Tri impossible",
                isPresented: Binding(
                    get: { cullingController.errorMessage != nil },
                    set: { if !$0 { cullingController.errorMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(cullingController.errorMessage ?? "")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Importer une carte…", systemImage: "sdcard", action: cardImportController.chooseCard)
                    .disabled(cardImportController.isSheetPresented)
                    .help("Copier les photos et vidéos d'une carte SD dans une nouvelle galerie")
            }
            ToolbarItem(placement: .navigation) {
                Button("Ajouter un dossier…", systemImage: "folder.badge.plus", action: importController.chooseFolder)
                    .disabled(importController.isIndexing)
                    .help("Indexer un dossier de photos sans le copier")
            }
            ToolbarItem(placement: .navigation) {
                Button("Doublons…", systemImage: "square.on.square") { isDuplicatesSheetPresented = true }
                    .disabled(galleries.isEmpty)
                    .help("Rechercher les fichiers identiques dans toutes vos galeries")
            }
        }
        .sheet(isPresented: $isDuplicatesSheetPresented) {
            DuplicatesSheet()
                .environment(duplicatesController)
        }
        .sheet(isPresented: Binding(
            get: { cardImportController.isSheetPresented },
            set: { if !$0 { cardImportController.close() } }
        )) {
            CardImportSheet()
                .environment(cardImportController)
        }
        .alert(
            "Import impossible",
            isPresented: Binding(
                get: { cardImportController.errorMessage != nil },
                set: { if !$0 { cardImportController.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(cardImportController.errorMessage ?? "")
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
        // Sidebar + every table column at its minimum width (see `GalleryDetailView`).
        .frame(minWidth: 1080, minHeight: 560)
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Gallery.self, Photo.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let store = makeStore(container)
    ContentView()
        .environment(ImportController(store: store))
        .environment(CullingController(store: store))
        .environment(ExportController())
        .environment(CardImportController(importer: CardImporter(store: store)))
        .environment(CardMonitor())
        .environment(DuplicatesController(store: store))
        .modelContainer(container)
}

/// The initializer generated by `@ModelActor` is not visible inside the `#Preview` macro.
private func makeStore(_ container: ModelContainer) -> LibraryStore {
    LibraryStore(modelContainer: container)
}
