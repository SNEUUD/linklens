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
            id: id, burstNumber: burstNumber, isBestOfBurst: isBestOfBurst, bestChosenAt: bestOfBurstChosenAt, verdict: verdict,
            isVerdictChosenByUser: isVerdictChosenByUser
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
    @Environment(DetailsBackfillController.self) private var detailsController
    @Environment(ReviewController.self) private var reviewController
    @Environment(PhotoDeletionController.self) private var photoDeletion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Query private var photos: [Photo]
    // `@AppStorage` is a `@State` saved in the user defaults (like `useState` backed by `localStorage`).
    @AppStorage("galleryLayout") private var layout = GalleryLayout.grid
    /// Whether the inspector is shown (batch 3), remembered between launches.
    @AppStorage("isInspectorShown") private var isInspectorShown = true
    /// Smallest width of a thumbnail, the same for every gallery (slider and ⌘+ / ⌘−).
    @AppStorage(ThumbnailSize.storageKey) private var thumbnailWidth = ThumbnailSize.standard
    /// « Montrer le sujet » in the viewer, remembered between launches.
    @AppStorage(PhotoViewer.showsSubjectKey) private var showsSubject = true
    @State private var browser: GalleryBrowser
    /// Manual sorting (P / U / X / A) with undo, shared by the grid, the table and the viewer.
    @State private var sorter: ManualSorter
    // `@State` keeps the same loader for the whole life of the view (like `useRef`), one per gallery.
    @State private var loader: ThumbnailLoader
    @State private var revealError: String?
    @State private var isExportSheetPresented = false
    /// Where the filter of each gallery is remembered.
    private let filterStore: VerdictFilterStore
    /// Told when the viewer opens or closes: the window then hides or shows its sidebar.
    private let onViewerChange: (Bool) -> Void
    /// Opens the deletion window; nil while the gallery cannot be deleted (with `deleteHelp` saying why).
    private let onDelete: (() -> Void)?
    private let deleteHelp: String

    /// - Parameters:
    ///   - thumbnailCache: the app's cache; the interface renders pass one of their own.
    ///   - onViewerChange: called with true when the full-window viewer opens, false when it closes.
    ///   - onDelete: « Supprimer la galerie… » of the « Galerie » menu (⌘⌫), nil when disabled.
    init(
        gallery: Gallery,
        thumbnailCache: ThumbnailCache = .standard,
        filterStore: VerdictFilterStore = VerdictFilterStore(),
        onViewerChange: @escaping (Bool) -> Void = { _ in },
        onDelete: (() -> Void)? = nil,
        deleteHelp: String = ""
    ) {
        self.gallery = gallery
        self.filterStore = filterStore
        self.onViewerChange = onViewerChange
        self.onDelete = onDelete
        self.deleteHelp = deleteHelp
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
            // The viewer and the review take the whole window: their own notice replaces the banner.
            if !availability.canUseOriginals, !isFullWindow {
                UnavailableGalleryBar(availability: availability)
            }
            if !photos.isEmpty, !isFullWindow {
                VerdictFilterBar(
                    filter: browser.filter,
                    counts: filterCounts,
                    onSelect: selectFilter,
                    thumbnailWidth: showsGrid ? $thumbnailWidth : nil,
                    review: reviewEntryPoint,
                    onReview: openReview,
                    trashRejected: trashRejectedAction
                )
            }
            content
                .frame(maxHeight: .infinity)
                // While the pill is shown, the last row can scroll above it instead of staying under it.
                .contentMargins(.bottom, activities.isEmpty || isFullWindow ? 0 : ActivityPillView.reservedHeight, for: .scrollContent)
        }
        // `safeAreaInset` pins the pill over the bottom of the photos: they scroll under it, and the
        // last row can still be scrolled above it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Not over the viewer's filmstrip nor the review: it comes back with the grid.
            if !isFullWindow, let pill = ActivityPill.content(for: activities) {
                ActivityPillView(content: pill, onCancel: cancel, onRevealExport: exportController.revealExportedFiles)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activities.map(\.kind))
        // `.inspector` adds a panel on the right that the user shows or hides (macOS 14+), like the
        // inspectors of Xcode or Pages. Its state is the stored `isInspectorShown`, shared with the
        // toolbar button and the « Présentation » menu (⌥⌘I).
        // Hidden over the review's summary, which shows no photo (the stored choice is left as it is).
        .inspector(isPresented: Binding(
            get: { isInspectorShown && !isReviewSummaryShown },
            set: { if !isReviewSummaryShown { isInspectorShown = $0 } }
        )) {
            Group {
                if !isFullWindow, browser.isMultipleSelection {
                    PhotoSelectionSummary(
                        photos: selectedPhotos,
                        loader: loader,
                        onTrash: canTrashSelection ? { requestTrash(browser.orderedSelection) } : nil,
                        trashHelp: trashHelp
                    )
                } else {
                    PhotoInspector(
                        photo: inspectedPhoto,
                        burstMembers: inspectedBurstMembers,
                        loader: loader,
                        canUseOriginals: availability.canUseOriginals,
                        onSort: { command in
                            guard let photoId = inspectedPhoto?.id else { return }
                            sorter.apply(command, to: [photoId])
                        }
                    )
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        // VoiceOver says when something starts or ends, like an `aria-live` region.
        .onChange(of: activities.map(\.kind)) { old, new in
            for activity in activities where !old.contains(activity.kind) {
                AccessibilityNotification.Announcement(activity.title).post()
            }
        }
        // VoiceOver says how many photos are selected when there are several.
        .onChange(of: browser.selectedIds.count) { _, count in
            if count > 1 { AccessibilityNotification.Announcement(PhotoDeletionText.selectedTitle(count: count)).post() }
        }
        // In the viewer, the window's title is the photo's name and its subtitle says where it is.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            if isReviewOpen {
                reviewToolbar
            } else if browser.isViewerOpen {
                viewerToolbar
            } else {
                galleryToolbar
            }
        }
        // Full window: a see-through toolbar over the viewer's background (the sidebar button is removed
        // by `ContentView`, which owns the sidebar).
        .toolbarBackgroundVisibility(isFullWindow ? .hidden : .automatic, for: .windowToolbar)
        .onChange(of: isFullWindow, initial: true) { _, isFull in onViewerChange(isFull) }
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
        .onDisappear {
            loader.stop()
            // Another gallery is shown: the review is left where it was (« Reprendre la revue »).
            if isReviewOpen { reviewController.close(galleryId: gallery.id) }
            onViewerChange(false)
        }
        // The environment is only known once the view is on screen; the window's undo manager can change.
        .onChange(of: undoManager, initial: true) {
            sorter.context = modelContext
            sorter.undoManager = undoManager
        }
        // Again after a sorting: the bursts are stored on the photos.
        .onChange(of: photos.map(\.burstInput), initial: true) { _, inputs in
            browser.setPhotos(inputs)
            reviewSession?.update(inputs)
        }
        // A new sorting changes the bursts and their best photos: a review under way starts again.
        .onChange(of: gallery.culledAt) {
            browser.gallerySortedAgain()
            reviewController.discard(galleryId: gallery.id)
        }
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

    /// Import | Grille / Liste | Trier à nouveau, Exporter… | Inspecteur.
    @ToolbarContentBuilder private var galleryToolbar: some ToolbarContent {
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

    /// The viewer's top bar, as in the mockup: « ‹ Grille » before the title, « Montrer le sujet » and the
    /// inspector on the right. On macOS 26 each item gets its glass capsule from the system.
    // `@ToolbarContentBuilder` lets a property list toolbar items, like `@ViewBuilder` for views.
    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: browser.closeViewer) {
                Label(layout == .table ? "Liste" : "Grille", systemImage: "chevron.left")
            }
            .labelStyle(.titleAndIcon)
            .help("Revenir aux photos (Espace ou Échap)")
        }
        ToolbarItem {
            Toggle(isOn: $showsSubject) {
                Label("Montrer le sujet", systemImage: "square.dashed")
            }
            .labelStyle(.titleAndIcon)
            .help(showsSubject ? "Masquer le cadre du sujet trouvé par l'IA" : "Entourer le sujet trouvé par l'IA")
        }
        InspectorToggle(isOn: $isInspectorShown)
    }

    /// The review's top bar: « ‹ Terminer » (Escape) before the title, the inspector on the right (not
    /// over the summary, where it is hidden).
    @ToolbarContentBuilder private var reviewToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: closeReview) {
                Label("Terminer", systemImage: "chevron.left")
            }
            .labelStyle(.titleAndIcon)
            .help("Quitter la revue (Échap). « Reprendre la revue » vous ramène ici.")
        }
        if !isReviewSummaryShown {
            InspectorToggle(isOn: $isInspectorShown)
        }
    }

    /// The photo shown by the viewer, nil while it is closed.
    private var viewerPhoto: Photo? {
        browser.isViewerOpen ? selectedPhoto : nil
    }

    private var windowTitle: Text {
        if isReviewOpen { return Text("Revue · \(gallery.name)") }
        return viewerPhoto.map { Text(verbatim: $0.fileName) } ?? Text(verbatim: gallery.name)
    }

    /// « 4 sur 9 · reste 12 photos à revoir » during the review.
    private var windowSubtitle: Text {
        if isReviewOpen, let session = reviewSession {
            guard !session.isFinished else { return Text("Revue terminée") }
            return Text(verbatim: ReviewText.counter(position: session.position, total: session.stops.count)
                + " · " + ReviewText.remaining(session.remainingCount))
        }
        return viewerPhoto == nil ? subtitle : Text(verbatim: viewerContext)
    }

    // MARK: - Review of the « À revoir » photos

    private var reviewSession: ReviewSession? {
        reviewController.session(for: gallery.id)
    }

    private var isReviewOpen: Bool {
        reviewSession?.isOpen == true
    }

    /// The review reached its summary: no photo to inspect.
    private var isReviewSummaryShown: Bool {
        isReviewOpen && reviewSession?.isFinished == true
    }

    /// The viewer or the review takes the whole window (sidebar, filters and pill hidden).
    private var isFullWindow: Bool {
        browser.isViewerOpen || isReviewOpen
    }

    /// « Revoir les 14 », « Reprendre la revue (reste 9) », or nil when nothing is « À revoir ».
    private var reviewEntryPoint: ReviewEntryPoint? {
        reviewController.entryPoint(galleryId: gallery.id, reviewCount: filterCounts.review)
    }

    /// The button, ⌘R or the menu: resumes the review left half-way, else starts one.
    private func openReview() {
        browser.closeViewer()
        reviewController.open(galleryId: gallery.id, photos: photos.map(\.burstInput))
    }

    /// Escape or « Terminer »: the grid comes back on the last photo shown; the position is kept.
    private func closeReview() {
        if let photoId = reviewSession?.focusedPhotoId {
            browser.reveal(photoId)
        }
        reviewController.close(galleryId: gallery.id)
    }

    /// « Revoir les N restantes » at the end: a new review of what is still « À revoir ».
    private func reviewRemaining() {
        reviewController.discard(galleryId: gallery.id)
        openReview()
    }

    /// « Rafale 4 ouverte · photo 5 sur 7 », « Photo 12 sur 52 », « À revoir · photo 3 sur 14 ».
    private var viewerContext: String {
        guard let index = browser.selectedIndex else { return "" }
        return ViewerContext.line(entries: browser.entries, index: index, photoCount: photos.count, filter: browser.filter)
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
        // Not over the full-window viewer (where ⌘⌫ could be taken for « delete this photo »), nor
        // while the export window is open.
        var delete: (@MainActor () -> Void)?
        if let onDelete, !isFullWindow, !isExportSheetPresented { delete = { onDelete() } }
        var review: (@MainActor () -> Void)?
        let entryPoint = reviewEntryPoint
        if entryPoint != nil, !isReviewOpen, !isExportSheetPresented { review = { openReview() } }
        // The selection: not over the full-window viewer or review, where it is not shown.
        var trashSelection: (@MainActor () -> Void)?
        if canTrashSelection, !browser.selectedIds.isEmpty {
            let ids = browser.orderedSelection
            trashSelection = { requestTrash(ids) }
        }
        var trashRejected: (@MainActor () -> Void)?
        if let action = trashRejectedAction { trashRejected = { action.perform() } }
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
            revealHelp: availability.help(for: .reveal) ?? defaultRevealHelp,
            delete: delete,
            deleteHelp: deleteHelp,
            reviewTitle: entryPoint?.menuTitle ?? String(localized: "Revoir les photos à revoir…"),
            review: review,
            trashSelection: trashSelection,
            trashRejectedTitle: PhotoDeletionText.rejectedMenuTitle(count: filterCounts.reject),
            trashRejected: trashRejected,
            trashHelp: trashHelp
        )
    }

    // MARK: - Photos to the trash

    /// Whether photos of this gallery can be deleted now (disk plugged in, nothing running on it, no
    /// other window open).
    private var canDeletePhotos: Bool {
        !isExportSheetPresented && photoDeletion.canRequest(galleryId: gallery.id)
    }

    private var canTrashSelection: Bool {
        canDeletePhotos && !isFullWindow
    }

    private var trashHelp: String {
        if let reason = photoDeletion.blockReason(galleryId: gallery.id) { return reason }
        if browser.selectedIds.isEmpty { return String(localized: "Sélectionnez d'abord des photos (⌘-clic, ⇧-clic, ⌘A).") }
        return String(localized: "Mettre les photos sélectionnées dans la corbeille du Finder, après confirmation. Vous pourrez annuler.")
    }

    /// « Mettre les 26 photos rejetées à la corbeille… »: nil when no photo is « Rejeter » or it is not possible now.
    private var trashRejectedAction: TrashRejectedAction? {
        let count = filterCounts.reject
        guard count > 0, canDeletePhotos else { return nil }
        return TrashRejectedAction(count: count) { requestTrashRejected() }
    }

    /// The confirmation window for these photos (display order kept).
    private func requestTrash(_ photoIds: [UUID]) {
        let byId = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = photoIds.compactMap { byId[$0]?.trashItem }
        photoDeletion.requestDeletion(
            PhotoDeletionRequest(galleryId: gallery.id, galleryName: gallery.name, kind: .selection, items: items),
            undoManager: undoManager
        )
    }

    private func requestTrashRejected() {
        photoDeletion.requestDeletion(.rejected(in: gallery, photos: photos), undoManager: undoManager)
    }

    /// The selected photos, in display order (the inspector's summary).
    private var selectedPhotos: [Photo] {
        let byId = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return browser.orderedSelection.compactMap { byId[$0] }
    }

    /// The photo the inspector shows: the selection of the grid, the table or the viewer (for a collapsed
    /// burst, its cover).
    private var selectedPhoto: Photo? {
        guard let selection = browser.selection else { return nil }
        return photos.first { $0.id == selection }
    }

    /// The photo the inspector shows: the one shown by the review while it is open, else the selection.
    private var inspectedPhoto: Photo? {
        guard isReviewOpen else { return selectedPhoto }
        guard let photoId = reviewSession?.focusedPhotoId else { return nil }
        return photos.first { $0.id == photoId }
    }

    /// Every photo of the inspected photo's burst, for « 7 photos prises dans la même seconde ».
    private var inspectedBurstMembers: [Photo] {
        guard let number = inspectedPhoto?.burstNumber else { return [] }
        return photos.filter { $0.burstNumber == number }
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
        // Shown in every gallery, like the duplicate search: it goes through all of them in turn.
        if detailsController.runningGalleryId != nil {
            activities.append(.details(detailsController.progress, startedAt: detailsController.startedAt ?? .distantPast))
        }
        if let progress = photoDeletion.progress, progress.galleryId == galleryId {
            activities.append(.photoTrash(progress))
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
        case .details: detailsController.cancel()
        case .photoTrash: photoDeletion.cancelTrashing()
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
        if isReviewOpen, let session = reviewSession {
            ReviewModeView(
                session: session,
                photosById: Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                loader: loader,
                sorter: sorter,
                availability: availability,
                onClose: closeReview,
                onReviewRemaining: reviewRemaining,
                trashRejected: trashRejectedAction
            )
            // A new review is a new view: its key handlers and zoom start afresh.
            .id(ObjectIdentifier(session))
        } else if browser.isViewerOpen, let index = rows.firstIndex(where: { $0.id == browser.selection }) {
            PhotoViewer(
                rows: rows, index: index, loader: loader, browser: browser, sorter: sorter, availability: availability,
                cellAspectRatio: cellAspectRatio
            )
        } else if rows.isEmpty, !photos.isEmpty, browser.filter != .all {
            EmptyFilterView(filter: browser.filter) { selectFilter(.all) }
        } else {
            switch layout {
            case .grid:
                GalleryGridView(
                    rows: rows, loader: loader, browser: browser, sorter: sorter,
                    canUseOriginals: availability.canUseOriginals,
                    cellAspectRatio: cellAspectRatio,
                    minimumCellWidth: thumbnailWidth,
                    onTrash: canTrashSelection ? { requestTrash($0) } : nil
                )
            case .table:
                GalleryTableView(rows: rows, browser: browser, sorter: sorter, onTrash: canTrashSelection ? { requestTrash($0) } : nil)
            }
        }
    }

    /// Width / height of the thumbnails, the dominant shape of the gallery (`ThumbnailShape`).
    private var cellAspectRatio: CGFloat {
        ThumbnailShape.cellAspectRatio(sizes: photos.map { ($0.pixelWidth, $0.pixelHeight) })
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

/// The inspector button, apart from the other buttons as in the mockup. ⌥⌘I belongs to the
/// « Présentation » menu item (one shortcut, one owner), which toggles the same stored value.
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
            .help(isOn ? "Masquer l'inspecteur (⌥⌘I)" : "Afficher l'inspecteur (⌥⌘I)")
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
