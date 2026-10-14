import AppKit
import SwiftData
import SwiftUI

/// How a gallery is shown. A `String` raw value lets `@AppStorage` save it.
enum GalleryLayout: String {
    case grid, table
}

/// A shown entry with its photo: what the grid, the table and the viewer draw.
struct DisplayedPhoto: Identifiable {
    let entry: GalleryEntry
    let photo: Photo

    var id: UUID { photo.id }
}

extension Photo {
    var burstInput: BurstStacks.Input {
        BurstStacks.Input(id: id, burstNumber: burstNumber, isBestOfBurst: isBestOfBurst)
    }
}

/// The photos of a gallery, as a grid of thumbnails or a table, a large viewer, the AI sorting (F3),
/// the bursts shown as stacks (F4) and the export (F6).
struct GalleryDetailView: View {
    let gallery: Gallery
    @Environment(CullingController.self) private var cullingController
    @Environment(ExportController.self) private var exportController
    @Query private var photos: [Photo]
    // `@AppStorage` is a `@State` saved in the user defaults (like `useState` backed by `localStorage`).
    @AppStorage("galleryLayout") private var layout = GalleryLayout.grid
    @State private var browser = GalleryBrowser()
    // `@State` keeps the same loader for the whole life of the view (like `useRef`), one per gallery.
    @State private var loader = ThumbnailLoader()
    @State private var revealError: String?
    @State private var isExportSheetPresented = false

    init(gallery: Gallery) {
        self.gallery = gallery
        let galleryId = gallery.id
        // `@Query` is the live query of SwiftData (like a `useQuery` hook that re-renders on every save).
        // Its filter depends on the gallery, so it is built here rather than in the property declaration.
        _photos = Query(
            filter: #Predicate<Photo> { $0.gallery?.id == galleryId },
            sort: [SortDescriptor(\.captureDate), SortDescriptor(\.relativePath)]
        )
    }

    var body: some View {
        content
        // `safeAreaInset` pins a bar above the photos, which scroll under it.
        .safeAreaInset(edge: .top, spacing: 0) {
            CullingStatusBar(gallery: gallery, photos: photos)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExportStatusBar(galleryId: gallery.id)
        }
        .navigationTitle(gallery.name)
        .navigationSubtitle(gallery.folderPath)
        .toolbar {
            Picker("Affichage", selection: $layout) {
                Label("Grille", systemImage: "square.grid.2x2").tag(GalleryLayout.grid)
                Label("Tableau", systemImage: "list.bullet").tag(GalleryLayout.table)
            }
            .pickerStyle(.segmented)
            .help("Afficher les photos en grille ou en tableau")
            Button(
                gallery.culledAt == nil ? "Trier les photos" : "Trier à nouveau",
                systemImage: "wand.and.stars"
            ) {
                cullingController.cull(galleryId: gallery.id)
            }
            .disabled(cullingController.isBusy(galleryId: gallery.id))
            .help("Proposer Garder, À revoir ou Rejeter pour chaque photo. Rien n'est supprimé.")
            Button("Exporter…", systemImage: "square.and.arrow.up") {
                isExportSheetPresented = true
            }
            .keyboardShortcut("e")
            .disabled(photos.isEmpty || exportController.isExporting)
            .help("Enregistrer des photos en JPEG, HEIC ou TIFF dans le dossier de votre choix. Les originaux ne sont pas modifiés.")
            Button("Afficher dans le Finder", systemImage: "folder", action: revealInFinder)
        }
        // `.sheet` shows a modal attached to the window while the Boolean is true (like `<Modal open={…}>`).
        .sheet(isPresented: $isExportSheetPresented) {
            ExportSheet(gallery: gallery, photos: photos, selectedPhotoId: browser.selection)
        }
        // Opens the folder (read only) and queues the missing thumbnails; again when photos are added.
        .task(id: photos.count) {
            loader.open(folderBookmark: gallery.folderBookmark)
            await loader.prefetch(photos.map(\.thumbnailRequest))
        }
        .onDisappear { loader.stop() }
        // Again after a sorting: the bursts are stored on the photos.
        .onChange(of: photos.map(\.burstInput), initial: true) { _, inputs in browser.setPhotos(inputs) }
        .onChange(of: gallery.culledAt) { browser.collapseAllBursts() }
        .onChange(of: layout) { browser.closeViewer() }
        .alert(
            "Dossier inaccessible",
            isPresented: Binding(get: { revealError != nil }, set: { if !$0 { revealError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(revealError ?? "")
        }
        .alert(
            "Export impossible",
            isPresented: Binding(
                get: { exportController.errorMessage != nil },
                set: { if !$0 { exportController.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(exportController.errorMessage ?? "")
        }
    }

    /// The viewer when it is open, otherwise the grid or the table.
    // `@ViewBuilder` lets a property return different views from an `if` / `switch`, like a JSX ternary.
    @ViewBuilder private var content: some View {
        let rows = rows
        if browser.isViewerOpen, let index = rows.firstIndex(where: { $0.id == browser.selection }) {
            PhotoViewer(rows: rows, index: index, loader: loader, browser: browser)
        } else {
            switch layout {
            case .grid:
                GalleryGridView(rows: rows, loader: loader, browser: browser)
            case .table:
                GalleryTableView(rows: rows, browser: browser)
            }
        }
    }

    /// The browser's entries with their photos. Right after a save, `photos` can be newer than the
    /// entries for one update: a photo is then looked up by its id instead of its index.
    private var rows: [DisplayedPhoto] {
        browser.entries.compactMap { entry in
            let photo = photos.indices.contains(entry.photoIndex) && photos[entry.photoIndex].id == entry.photoId
                ? photos[entry.photoIndex]
                : photos.first { $0.id == entry.photoId }
            return photo.map { DisplayedPhoto(entry: entry, photo: $0) }
        }
    }

    /// Reopens the folder through its bookmark: also checks that access survives a restart.
    private func revealInFinder() {
        do {
            let folder = try FolderBookmark.resolve(gallery.folderBookmark)
            guard folder.startAccessingSecurityScopedResource() else {
                throw LibraryError.accessDenied(gallery.name)
            }
            defer { folder.stopAccessingSecurityScopedResource() }
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw LibraryError.folderNotFound(gallery.folderPath)
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            revealError = error.localizedDescription
        }
    }
}

/// Above the photos: progress and "Annuler" while sorting, otherwise the number of photos per verdict.
private struct CullingStatusBar: View {
    let gallery: Gallery
    let photos: [Photo]
    @Environment(CullingController.self) private var cullingController

    var body: some View {
        if let progress = cullingController.progress, progress.galleryId == gallery.id {
            bar {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 240)
                Text("Tri des photos : \(progress.completed) sur \(progress.total)")
                    .monospacedDigit()
                Spacer()
                Button("Annuler") { cullingController.cancel(galleryId: gallery.id) }
            }
        } else if cullingController.isQueued(galleryId: gallery.id) {
            bar {
                ProgressView().controlSize(.small)
                Text("Tri en attente…")
                Spacer()
                Button("Annuler") { cullingController.cancel(galleryId: gallery.id) }
            }
        } else if gallery.culledAt != nil {
            bar {
                count(of: .keep)
                count(of: .review)
                count(of: .reject)
                let burstCount = Set(photos.compactMap(\.burstNumber)).count
                if burstCount > 0 {
                    Label("Rafales : \(burstCount)", systemImage: "square.stack")
                        .monospacedDigit()
                        .help("Chaque rafale est montrée par sa meilleure photo. Touche S : voir toute la rafale ou la replier.")
                }
                Spacer()
                Text("Proposition de l'IA : rien n'est supprimé.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func count(of verdict: CullingVerdict) -> some View {
        let total = photos.filter { $0.cullingVerdict == verdict }.count
        return HStack(spacing: 6) {
            Circle().fill(verdict.color).frame(width: 8, height: 8)
            Text(verbatim: "\(verdict.label) : \(total)")
                .monospacedDigit()
        }
    }

    // `@ViewBuilder` lets a function take several views as content, like `children` in React.
    private func bar(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12, content: content)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
        }
        .background(.bar)
    }
}
