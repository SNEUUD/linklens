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
    @Environment(GalleryAvailabilityMonitor.self) private var availabilityMonitor
    @Environment(\.thumbnailCache) private var thumbnailCache
    @Query(sort: \Gallery.createdAt, order: .reverse) private var galleries: [Gallery]
    @State private var isDuplicatesSheetPresented = false
    /// Sidebar shown or not. The full-window viewer hides it and puts it back as it was when it closes.
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var visibilityBeforeViewer: NavigationSplitViewVisibility?

    var body: some View {
        // `@Bindable` gives two-way bindings (`$…`) to the properties of an `@Observable` object.
        @Bindable var importController = importController

        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(
                galleries: galleries,
                selection: $importController.selectedGalleryId,
                indexing: importController.progress,
                onCancelIndexing: importController.cancelIndexing,
                availability: availabilityMonitor.availability(of:),
                cards: cardMonitor.cards,
                onImportCard: { card in
                    if cardImportController.importCard(card) {
                        cardMonitor.dismiss(card)
                    }
                },
                onDismissCard: cardMonitor.dismiss,
                onShowDuplicates: { isDuplicatesSheetPresented = true }
            )
            // No sidebar button while the viewer takes the whole window: « ‹ Grille » brings it back.
            .toolbar(removing: visibilityBeforeViewer == nil ? nil : .sidebarToggle)
        } detail: {
            // `Group` wraps the branches so one modifier (the alert) applies to all of them.
            Group {
                if let gallery = galleries.first(where: { $0.id == importController.selectedGalleryId }) {
                    GalleryDetailView(gallery: gallery, thumbnailCache: thumbnailCache, onViewerChange: viewerChanged)
                        .id(gallery.id)
                } else if galleries.isEmpty {
                    ContentUnavailableView {
                        Label("Aucune galerie", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Importez une carte SD ou un dossier de photos pour commencer.")
                    } actions: {
                        ImportMenuItems(showsShortcuts: false, cardTitle: "Importer une carte SD…", folderTitle: "Ajouter un dossier…")
                    }
                    .toolbar { ImportToolbarMenu() }
                } else {
                    ContentUnavailableView("Sélectionnez une galerie", systemImage: "sidebar.left")
                        .toolbar { ImportToolbarMenu() }
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
    }

    /// The viewer takes the whole window (as in the mockup): the sidebar folds away while it is open.
    private func viewerChanged(_ isOpen: Bool) {
        // Not animated: an animated sidebar while the toolbar changes made AppKit loop over its
        // constraints until it crashed (seen in the interface renders).
        if isOpen {
            if visibilityBeforeViewer == nil { visibilityBeforeViewer = columnVisibility }
            columnVisibility = .detailOnly
        } else if let previous = visibilityBeforeViewer {
            columnVisibility = previous
            visibilityBeforeViewer = nil
        }
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
        .environment(GalleryAvailabilityMonitor(store: store))
        .environment(DetailsBackfillController(store: store))
        .modelContainer(container)
}

/// The initializer generated by `@ModelActor` is not visible inside the `#Preview` macro.
private func makeStore(_ container: ModelContainer) -> LibraryStore {
    LibraryStore(modelContainer: container)
}
