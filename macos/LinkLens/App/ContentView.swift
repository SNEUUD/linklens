import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    /// A folder is being dragged over the window.
    @State private var isDropTargeted: Bool
    /// Something was dropped that is not one folder: the alert says what to do instead.
    @State private var dropRejection: FolderDrop.Rejection?

    /// `isDropTargeted` lets the interface renders show the window during a drag.
    init(isDropTargeted: Bool = false) {
        _isDropTargeted = State(initialValue: isDropTargeted)
    }

    private var isViewerOpen: Bool { visibilityBeforeViewer != nil }

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
            // Last modifier of the column: placed before `.toolbar(removing:)`, the width was ignored and the
            // sidebar opened at its narrowest (since batch 4).
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            // `Group` wraps the branches so one modifier (the alert) applies to all of them.
            Group {
                if let gallery = galleries.first(where: { $0.id == importController.selectedGalleryId }) {
                    GalleryDetailView(gallery: gallery, thumbnailCache: thumbnailCache, onViewerChange: viewerChanged)
                        .id(gallery.id)
                } else if galleries.isEmpty {
                    WelcomeView(isDropTargeted: isDropTargeted)
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
        .overlay {
            if isDropTargeted {
                FolderDropHighlight(showsMessage: !galleries.isEmpty)
                    // Around the whole window, toolbar included: the drop works anywhere in it.
                    .ignoresSafeArea()
            }
        }
        // A folder dragged from the Finder, anywhere in the window (sidebar included). Not while the
        // viewer takes the whole window: closing it first would lose the photo being looked at.
        // `.onDrop` is like `onDragOver` + `onDrop` on a React element; `isTargeted` follows the hovering.
        .onDrop(of: isViewerOpen ? [] : [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task { await handleDrop(providers) }
            return true
        }
        .onChange(of: isDropTargeted) { _, isTargeted in
            if isTargeted {
                AccessibilityNotification.Announcement(String(localized: "Déposez le dossier pour l'ajouter")).post()
            }
        }
        .sheet(isPresented: $isDuplicatesSheetPresented) {
            DuplicatesSheet()
                .environment(duplicatesController)
                .environment(availabilityMonitor)
        }
        .focusedSceneValue(\.showDuplicates, galleries.isEmpty ? nil : MenuAction { isDuplicatesSheetPresented = true })
        // A gallery added (or removed): its disk is checked, and its name remembered (F9).
        .onChange(of: galleries.map(\.id)) { availabilityMonitor.refresh() }
        .sheet(isPresented: Binding(
            get: { cardImportController.isSheetPresented },
            set: { if !$0 { cardImportController.close() } }
        )) {
            CardImportSheet()
                .environment(cardImportController)
                .environment(\.thumbnailCache, thumbnailCache)
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
        .alert(
            dropRejection?.title ?? "",
            isPresented: Binding(
                get: { dropRejection != nil },
                set: { if !$0 { dropRejection = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(dropRejection?.message ?? "")
        }
    }

    /// One folder: a new gallery indexed in place (F2). The card of a camera: the card import (F1).
    /// Anything else: an alert that says what to drop instead.
    private func handleDrop(_ providers: [NSItemProvider]) async {
        let urls = await FolderDrop.fileURLs(from: providers)
        let items = urls.map { (url: $0, item: FolderDrop.item(at: $0)) }
        switch FolderDrop.decide(items) {
        case .indexFolder(let folder):
            importController.indexDroppedFolder(folder)
        case .importCard(let card):
            cardImportController.importDroppedCard(card)
        case .rejected(let rejection):
            dropRejection = rejection
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
