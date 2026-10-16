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
        BurstStacks.Input(
            id: id, burstNumber: burstNumber, isBestOfBurst: isBestOfBurst, bestChosenAt: bestOfBurstChosenAt, verdict: verdict
        )
    }
}

/// The photos of a gallery, as a grid of thumbnails or a table, a large viewer, the AI sorting (F3),
/// the bursts shown as stacks (F4) and the export (F6). Above the photos, the verdict filters; at the
/// bottom, the progress pill of whatever runs for this gallery.
struct GalleryDetailView: View {
    let gallery: Gallery
    @Environment(ImportController.self) private var importController
    @Environment(CullingController.self) private var cullingController
    @Environment(ExportController.self) private var exportController
    @Environment(DuplicatesController.self) private var duplicatesController
    @Environment(GalleryAvailabilityMonitor.self) private var availabilityMonitor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Query private var photos: [Photo]
    // `@AppStorage` is a `@State` saved in the user defaults (like `useState` backed by `localStorage`).
    @AppStorage("galleryLayout") private var layout = GalleryLayout.grid
    /// Whether the inspector is shown (batch 3), remembered between launches.
    @AppStorage("isInspectorShown") private var isInspectorShown = true
    /// Smallest width of a thumbnail, the same for every gallery (slider and ⌘+ / ⌘−).
    @AppStorage(ThumbnailSize.storageKey) private var thumbnailWidth = ThumbnailSize.standard
    @State private var browser: GalleryBrowser
    /// Manual sorting (P / U / X / A) with undo, shared by the grid, the table and the viewer.
    @State private var sorter: ManualSorter
    // `@State` keeps the same loader for the whole life of the view (like `useRef`), one per gallery.
    @State private var loader: ThumbnailLoader
    @State private var revealError: String?
    @State private var isExportSheetPresented = false
    /// Where the filter of each gallery is remembered.
    private let filterStore: VerdictFilterStore

    /// - Parameter thumbnailCache: the app's cache; the interface renders pass one of their own.
    init(gallery: Gallery, thumbnailCache: ThumbnailCache = .standard, filterStore: VerdictFilterStore = VerdictFilterStore()) {
        self.gallery = gallery
        self.filterStore = filterStore
        _loader = State(initialValue: ThumbnailLoader(cache: thumbnailCache))
        let browser = GalleryBrowser()
        // The filter chosen last time in this gallery.
        browser.setFilter(filterStore.filter(galleryId: gallery.id))
        _browser = State(initialValue: browser)
        _sorter = State(initialValue: ManualSorter(browser: browser))
        let galleryId = gallery.id
        // `@Query` is the live query of SwiftData (like a `useQuery` hook that re-renders on every save).
        // Its filter depends on the gallery, so it is built here rather than in the property declaration.
        _photos = Query(
            filter: #Predicate<Photo> { $0.gallery?.id == galleryId },
            sort: [SortDescriptor(\.captureDate), SortDescriptor(\.relativePath)]
        )
    }

    /// Whether the original files can be read now (F9). Without them, everything still shows from
    /// the cached thumbnails and only export, sorting and "Afficher dans le Finder" wait.
    private var availability: GalleryAvailability {
        availabilityMonitor.availability(of: gallery.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !availability.canUseOriginals {
                UnavailableGalleryBar(availability: availability)
            }
            if !photos.isEmpty {
                VerdictFilterBar(
                    filter: browser.filter,
                    counts: filterCounts,
                    onSelect: selectFilter,
                    thumbnailWidth: showsGrid ? $thumbnailWidth : nil
                )
            }
            content
                .frame(maxHeight: .infinity)
        }
        // `safeAreaInset` pins the pill over the bottom of the photos: they scroll under it, and the
        // last row can still be scrolled above it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let pill = ActivityPill.content(for: activities) {
                ActivityPillView(content: pill, onCancel: cancel, onRevealExport: exportController.revealExportedFiles)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activities.map(\.kind))
        // VoiceOver says when something starts or ends, like an `aria-live` region.
        .onChange(of: activities.map(\.kind)) { old, new in
            for activity in activities where !old.contains(activity.kind) {
                AccessibilityNotification.Announcement(activity.title).post()
            }
        }
        .navigationTitle(gallery.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            // Each `ToolbarItemGroup` is drawn as one capsule, as in the mockup.
            ToolbarItemGroup {
                ImportToolbarMenu()
            }
            ToolbarItemGroup {
                Picker("Affichage", selection: $layout) {
                    Label("Grille", systemImage: "square.grid.2x2").tag(GalleryLayout.grid)
                    Label("Liste", systemImage: "list.bullet").tag(GalleryLayout.table)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Afficher les photos en grille ou en liste")
            }
            ToolbarItemGroup {
                galleryActionButtons
            }
            InspectorToggle(isOn: $isInspectorShown)
        }
        // Publishes the actions of this gallery to the « Galerie » and « Présentation » menus.
        .focusedSceneValue(\.galleryMenuActions, menuActions)
        .focusedSceneValue(\.galleryPresentation, presentationActions)
        // `.sheet` shows a modal attached to the window while the Boolean is true (like `<Modal open={…}>`).
        .sheet(isPresented: $isExportSheetPresented) {
            ExportSheet(gallery: gallery, photos: photos, selectedPhotoId: browser.selection)
        }
        // Opens the folder (read only) and queues the missing thumbnails; again when photos are added
        // and when the disk comes back. When it goes away, the folder is let go: cached thumbnails only.
        .task(id: ThumbnailTaskKey(photoCount: photos.count, canUseOriginals: availability.canUseOriginals)) {
            if availability.canUseOriginals {
                loader.open(folderBookmark: gallery.folderBookmark)
                await loader.prefetch(photos.map(\.thumbnailRequest))
            } else {
                loader.closeFolder()
            }
        }
        .onDisappear { loader.stop() }
        // The environment is only known once the view is on screen; the window's undo manager can change.
        .onChange(of: undoManager, initial: true) {
            sorter.context = modelContext
            sorter.undoManager = undoManager
        }
        // Again after a sorting: the bursts are stored on the photos.
        .onChange(of: photos.map(\.burstInput), initial: true) { _, inputs in browser.setPhotos(inputs) }
        .onChange(of: gallery.culledAt) { browser.gallerySortedAgain() }
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

    /// « Trier à nouveau » (icon) and « Exporter… », with the same rules as the « Galerie » menu.
    @ViewBuilder private var galleryActionButtons: some View {
        let actions = menuActions
        Button(actions.cullTitle, systemImage: "wand.and.stars") { actions.cull?() }
            .labelStyle(.iconOnly)
            .disabled(actions.cull == nil)
            .help(actions.cullHelp)
        Button("Exporter…", systemImage: "square.and.arrow.up") { actions.export?() }
            .labelStyle(.titleAndIcon)
            .disabled(actions.export == nil)
            .help(actions.exportHelp)
    }

    /// The gallery actions of the toolbar and of the « Galerie » menu, with the F9 rules: an action
    /// that reads the originals is nil (disabled) while they are out of reach, and its help says why.
    private var menuActions: GalleryMenuActions {
        let galleryId = gallery.id
        let cullingController = cullingController
        let canCull = !cullingController.isBusy(galleryId: galleryId) && availability.canUseOriginals
        let canExport = !photos.isEmpty && !exportController.isExporting && availability.canUseOriginals
        // Nil (a disabled item) unless the action is possible now.
        var cull: (@MainActor () -> Void)?
        var export: (@MainActor () -> Void)?
        var reveal: (@MainActor () -> Void)?
        if canCull { cull = { cullingController.cull(galleryId: galleryId) } }
        if canExport { export = { isExportSheetPresented = true } }
        if availability.canUseOriginals { reveal = { revealInFinder() } }
        let defaultCullHelp = String(localized: "Proposer Garder, À revoir ou Rejeter pour chaque photo. Rien n'est supprimé.")
        let defaultExportHelp = String(localized: "Enregistrer des photos en JPEG, HEIC ou TIFF dans le dossier de votre choix. Les originaux ne sont pas modifiés.")
        let defaultRevealHelp = String(localized: "Afficher le dossier de la galerie dans le Finder")
        return GalleryMenuActions(
            cullTitle: gallery.culledAt == nil ? String(localized: "Trier les photos") : String(localized: "Trier à nouveau"),
            cull: cull,
            cullHelp: availability.help(for: .cull) ?? defaultCullHelp,
            export: export,
            exportHelp: availability.help(for: .export) ?? defaultExportHelp,
            reveal: reveal,
            revealHelp: availability.help(for: .reveal) ?? defaultRevealHelp
        )
    }

    /// The grid is on screen (the size slider and ⌘+ / ⌘− only apply to it).
    private var showsGrid: Bool {
        layout == .grid && !browser.isViewerOpen
    }

    private var filterCounts: VerdictFilterCounts {
        VerdictFilterCounts(photos.map(\.verdict))
    }

    /// A click on a filter or ⌘1–⌘4: shows it (again) and remembers it for this gallery.
    private func selectFilter(_ filter: VerdictFilter) {
        browser.setFilter(filter)
        filterStore.setFilter(filter, galleryId: gallery.id)
    }

    /// The filters and thumbnail sizes of the « Présentation » menu.
    private var presentationActions: GalleryPresentationActions {
        GalleryPresentationActions(
            filter: browser.filter,
            counts: filterCounts,
            select: { selectFilter($0) },
            canResizeThumbnails: showsGrid
        )
    }

    /// What runs for this gallery now (and the duplicate search, which covers every gallery).
    private var activities: [Activity] {
        let galleryId = gallery.id
        var activities: [Activity] = []
        if let progress = importController.progress, progress.galleryId == galleryId {
            activities.append(.indexing(progress, startedAt: importController.startedAt ?? .distantPast))
        }
        if cullingController.runningGalleryId == galleryId {
            let progress = cullingController.progress?.galleryId == galleryId ? cullingController.progress : nil
            activities.append(.culling(progress, isQueued: false, startedAt: cullingController.startedAt))
        } else if cullingController.isQueued(galleryId: galleryId) {
            activities.append(.culling(nil, isQueued: true, startedAt: nil))
        }
        if let progress = exportController.progress, progress.galleryId == galleryId {
            activities.append(.export(progress, startedAt: exportController.startedAt ?? .distantPast))
        } else if let summary = exportController.summary, summary.galleryId == galleryId {
            activities.append(.exportFinished(summary, at: exportController.finishedAt ?? .distantPast))
        }
        if duplicatesController.isScanning {
            activities.append(.duplicates(duplicatesController.progress, startedAt: duplicatesController.scanStartedAt ?? .distantPast))
        }
        return activities
    }

    /// « Annuler » (or « Fermer ») in the progress pill.
    private func cancel(_ kind: Activity.Kind) {
        switch kind {
        case .indexing: importController.cancelIndexing()
        case .culling: cullingController.cancel(galleryId: gallery.id)
        case .export: exportController.cancel()
        case .exportFinished: exportController.dismissSummary()
        case .duplicates: duplicatesController.cancelScan()
        }
    }

    /// « 52 photos · triée par l'IA · ~/Downloads/photos » under the gallery name.
    private var subtitle: Text {
        let summary = GallerySummary(photos.map(\.summaryItem))
        let state = gallery.culledAt == nil ? Text("pas encore triée") : Text("triée par l'IA")
        return Text("^[\(summary.photoCount) photo](inflect: true)") + Text(verbatim: " · ") + state
            + Text(verbatim: " · " + abbreviatedPath(gallery.folderPath, home: realHomeDirectory()))
    }

    /// The viewer when it is open, otherwise the grid or the table (or a word when the filter is empty).
    // `@ViewBuilder` lets a property return different views from an `if` / `switch`, like a JSX ternary.
    @ViewBuilder private var content: some View {
        let rows = rows
        if browser.isViewerOpen, let index = rows.firstIndex(where: { $0.id == browser.selection }) {
            PhotoViewer(rows: rows, index: index, loader: loader, browser: browser, sorter: sorter, availability: availability)
        } else if rows.isEmpty, !photos.isEmpty, browser.filter != .all {
            EmptyFilterView(filter: browser.filter) { selectFilter(.all) }
        } else {
            switch layout {
            case .grid:
                GalleryGridView(
                    rows: rows, loader: loader, browser: browser, sorter: sorter,
                    canUseOriginals: availability.canUseOriginals,
                    cellAspectRatio: ThumbnailShape.cellAspectRatio(sizes: photos.map { ($0.pixelWidth, $0.pixelHeight) }),
                    minimumCellWidth: thumbnailWidth
                )
            case .table:
                GalleryTableView(rows: rows, browser: browser, sorter: sorter)
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

/// The inspector button, apart from the other buttons as in the mockup. The inspector itself comes
/// with batch 3; its button and remembered state are ready.
private struct InspectorToggle: ToolbarContent {
    @Binding var isOn: Bool

    // `ToolbarContent` is to the toolbar what `View` is to the window: a piece of it, built in `body`.
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            // A gap between two groups of buttons: each group gets its own glass capsule.
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            // A `Toggle` in a toolbar is drawn as a button that stays pressed while on.
            Toggle(isOn: $isOn) {
                Label("Inspecteur", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(isOn ? "Masquer l'inspecteur" : "Afficher l'inspecteur")
        }
    }
}

/// What the thumbnails task depends on: it runs again when one of them changes.
/// `Hashable` lets SwiftUI compare two keys, like the dependency array of a `useEffect`.
private struct ThumbnailTaskKey: Hashable {
    var photoCount: Int
    var canUseOriginals: Bool
}

/// Above the photos when the originals are out of reach (F9): « Disque « Photos 2TB » non connecté »,
/// on a glass banner like the other floating elements. Same message and advice as before.
struct UnavailableGalleryBar: View {
    let availability: GalleryAvailability

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: availability.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.review.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(availability.message ?? "")
                    .fontWeight(.semibold)
                if let advice = availability.advice {
                    Text(advice)
                        .foregroundStyle(.secondary)
                        // Not `.fixedSize`: a text that may grow without limit made SwiftUI ask for a
                        // huge window (see `SidebarLayoutTests`).
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassBackground(in: RoundedRectangle(cornerRadius: Radius.card))
        .padding(.horizontal, GridLayout.padding)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Under a verdict filter that matches no photo: says so, and offers to show every photo.
private struct EmptyFilterView: View {
    let filter: VerdictFilter
    let showAll: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Aucune photo « \(filter.title) »", systemImage: filter.verdict?.symbolName ?? "photo")
        } description: {
            Text("Les photos que vous triez restent visibles jusqu'au prochain changement de filtre.")
        } actions: {
            Button("Afficher toutes les photos (⌘1)", action: showAll)
        }
    }
}

/// Where the verdict filter of each gallery is remembered between launches: in the user defaults,
/// one key per gallery (like a `localStorage` entry per page).
struct VerdictFilterStore {
    var defaults: UserDefaults = .standard

    func filter(galleryId: UUID) -> VerdictFilter {
        defaults.string(forKey: VerdictFilter.storageKey(galleryId: galleryId)).flatMap(VerdictFilter.init(rawValue:)) ?? .all
    }

    func setFilter(_ filter: VerdictFilter, galleryId: UUID) {
        let key = VerdictFilter.storageKey(galleryId: galleryId)
        // « Toutes » is the default: nothing to keep.
        if filter == .all {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(filter.rawValue, forKey: key)
        }
    }
}

extension GalleryAvailability {
    var systemImage: String {
        switch self {
        case .available: "externaldrive"
        case .diskDisconnected: "externaldrive.badge.xmark"
        case .folderMissing: "questionmark.folder"
        }
    }
}
