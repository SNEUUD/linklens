import AppKit
import Observation
import SwiftUI

/// The gallery the confirmation window is about, as plain values (never the `@Model` object itself,
/// which may be gone from the catalogue while the window closes).
struct GalleryDeletionRequest: Sendable, Equatable, Identifiable {
    var galleryId: UUID
    var name: String
    var photoCount: Int
    var videoCount: Int
    var folderPath: String

    var id: UUID { galleryId }

    init(galleryId: UUID, name: String, photoCount: Int, videoCount: Int, folderPath: String) {
        self.galleryId = galleryId
        self.name = name
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.folderPath = folderPath
    }

    @MainActor
    init(_ gallery: Gallery) {
        // `Gallery.photoCount` counts the videos too.
        self.init(
            galleryId: gallery.id, name: gallery.name, photoCount: gallery.photoCount - gallery.videoCount,
            videoCount: gallery.videoCount, folderPath: gallery.folderPath
        )
    }
}

/// The glass banner shown after a deletion (with « Annuler ») and after an undo.
struct GalleryDeletionBanner: Equatable {
    enum Kind: Equatable {
        /// `folderTrashed`: the folder went to the trash with the gallery.
        case deleted(folderTrashed: Bool)
        /// `problem`: why the folder stayed in the trash, nil when everything came back.
        case restored(problem: String?)
    }

    var galleryId: UUID
    var galleryName: String
    var kind: Kind

    var canUndo: Bool {
        if case .deleted = kind { true } else { false }
    }

    var title: String {
        switch kind {
        case .deleted: String(localized: "« \(galleryName) » supprimée de LinkLens")
        case .restored: String(localized: "« \(galleryName) » est de retour")
        }
    }

    var detail: String? {
        switch kind {
        case .deleted(let folderTrashed):
            folderTrashed ? String(localized: "Le dossier est dans la corbeille.") : String(localized: "Le dossier est resté à sa place.")
        case .restored(let problem):
            problem
        }
    }

    /// What VoiceOver says when the banner appears.
    var announcement: String {
        switch kind {
        case .deleted: [title, detail ?? "", String(localized: "Commande Z pour annuler.")].joined(separator: ". ")
        case .restored: [title, detail].compactMap(\.self).joined(separator: ". ")
        }
    }
}

/// Deleting a gallery: the confirmation window, the deletion itself, « Annuler » (⌘Z and the banner)
/// and, once the undo is no longer possible, the cleaning of the cached thumbnails.
///
/// What goes: the gallery, its photos and the user's choices (in the catalogue), its bookmarks (they
/// are stored on the gallery), and its folder only if the box was ticked, always to the trash.
/// Lives as long as the app, like `DuplicatesController`, so the undo survives the window's changes.
@MainActor
@Observable
final class GalleryDeletionController {
    /// How long « Annuler » stays possible. Then the thumbnails leave the cache.
    static let standardUndoPeriod: Duration = .seconds(10 * 60)
    /// How long the banner stays (it stays until closed when VoiceOver is on).
    static let standardBannerDuration: Duration = .seconds(15)

    /// The confirmation window is shown while this is set.
    private(set) var request: GalleryDeletionRequest?
    /// What the window knows about the folder; nil while it is being looked at.
    private(set) var folderCheck: FolderTrashCheck?
    /// « Mettre aussi le dossier à la corbeille », unticked each time the window opens.
    var alsoTrashFolder = false
    private(set) var isDeleting = false
    /// Shown inside the window while it is open, as an alert otherwise.
    var errorMessage: String?
    private(set) var banner: GalleryDeletionBanner?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let cache: ThumbnailCache
    @ObservationIgnored private let purgeQueue: ThumbnailPurgeQueue
    @ObservationIgnored private let undoPeriod: Duration
    @ObservationIgnored private let bannerDuration: Duration
    /// Asks the user to allow changes in the folder (the « Autoriser » panel). Nil if refused.
    @ObservationIgnored private let requestWriteAccess: @MainActor (GalleryLocation) -> URL?

    // Set by the app (closures stored in properties, like function props in React).
    /// F9: whether the gallery's disk is plugged in.
    @ObservationIgnored var galleryAvailability: @MainActor (UUID) -> GalleryAvailability = { _ in .available }
    /// True while the gallery is indexed, sorted, exported… : it cannot be deleted meanwhile.
    @ObservationIgnored var isBusy: @MainActor (UUID) -> Bool = { _ in false }
    /// The folders that never go to the trash (see `FolderTrashRules.protectedPaths`).
    @ObservationIgnored var protectedPaths: @MainActor () -> [String] = { FolderTrashRules.protectedPaths(home: realHomeDirectory()) }
    /// The gallery shown in the window, and a way to show another one.
    @ObservationIgnored var selectedGalleryId: @MainActor () -> UUID? = { nil }
    @ObservationIgnored var selectGallery: @MainActor (UUID?) -> Void = { _ in }

    /// The window's undo manager, given with the request: ⌘Z and the Edit menu use it.
    @ObservationIgnored private weak var undoManager: UndoManager?
    /// Deletions that can still be undone, by gallery id.
    @ObservationIgnored private var records: [UUID: DeletionRecord] = [:]
    @ObservationIgnored private var inspectTask: Task<Void, Never>?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var undoTasks: [UUID: Task<Void, Never>] = [:]

    init(
        store: LibraryStore,
        cache: ThumbnailCache = .standard,
        purgeQueue: ThumbnailPurgeQueue = .standard,
        undoPeriod: Duration = GalleryDeletionController.standardUndoPeriod,
        bannerDuration: Duration = GalleryDeletionController.standardBannerDuration,
        requestWriteAccess: @escaping @MainActor (GalleryLocation) -> URL? = GalleryDeletionController.askForWriteAccess
    ) {
        self.store = store
        self.cache = cache
        self.purgeQueue = purgeQueue
        self.undoPeriod = undoPeriod
        self.bannerDuration = bannerDuration
        self.requestWriteAccess = requestWriteAccess
    }

    // MARK: - Confirmation window

    func canDelete(galleryId: UUID) -> Bool {
        request == nil && !isDeleting && !isBusy(galleryId) && records[galleryId] == nil
    }

    /// Opens the confirmation window, then looks at the folder in the background.
    func requestDeletion(_ request: GalleryDeletionRequest, undoManager: UndoManager?) {
        guard canDelete(galleryId: request.galleryId) else { return }
        self.request = request
        self.undoManager = undoManager
        alsoTrashFolder = false
        folderCheck = nil
        errorMessage = nil
        inspectTask = Task {
            let check = await inspectFolder(galleryId: request.galleryId)
            guard self.request?.galleryId == request.galleryId else { return }
            folderCheck = check
        }
    }

    /// « Annuler » or Escape: nothing changes.
    func cancel() {
        guard !isDeleting else { return }
        inspectTask?.cancel()
        request = nil
        folderCheck = nil
        alsoTrashFolder = false
        errorMessage = nil
    }

    /// « Supprimer ». The folder goes to the trash only if the box is ticked and every safeguard still
    /// passes; if moving it fails, nothing is deleted at all.
    func confirm() {
        guard let request, !isDeleting else { return }
        let wantsFolder = alsoTrashFolder && folderCheck?.isAllowed == true
        isDeleting = true
        errorMessage = nil
        deleteTask = Task {
            defer {
                isDeleting = false
                deleteTask = nil
            }
            do {
                try await delete(request, withFolder: wantsFolder)
            } catch let error as GalleryDeletionError {
                errorMessage = error.localizedDescription
                // The window stays open: the box shows the fresh reason it is greyed out.
                if case .folderBlocked = error {
                    folderCheck = await inspectFolder(galleryId: request.galleryId)
                    alsoTrashFolder = false
                }
            } catch is CancellationError {
                // « Autoriser » refused: nothing happened, the window stays open.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ request: GalleryDeletionRequest, withFolder: Bool) async throws {
        let galleries = try await store.galleryLocations()
        guard let gallery = galleries.first(where: { $0.id == request.galleryId }) else { throw LibraryError.galleryNotFound }
        let others = galleries.filter { $0.id != gallery.id }.map { FolderTrashRules.GalleryFolder(name: $0.name, path: $0.folderPath) }

        // 1. The folder, first: if it cannot go, nothing is deleted.
        var trashed: TrashedFolder?
        var accessedFolder: URL?
        if withFolder {
            // Checked again now (a disk may have been unplugged since the window opened).
            let check = await GalleryFolderTrasher.inspect(
                gallery, availability: galleryAvailability(gallery.id), otherGalleries: others, protectedPaths: protectedPaths()
            )
            if let block = check.block { throw GalleryDeletionError.folderBlocked(block) }
            switch await GalleryWriteAccess.open(gallery, store: store, askUser: requestWriteAccess) {
            case .refused:
                throw CancellationError()
            case .wrongFolder:
                throw GalleryDeletionError.trashFailed(String(localized: "choisissez le dossier « \(gallery.name) » lui-même dans la fenêtre « Autoriser »"))
            case .opened(let folder, let isAccessing):
                do {
                    trashed = try await GalleryFolderTrasher.moveToTrash(
                        folder, expectedPath: check.folderPath, otherGalleries: others, protectedPaths: protectedPaths()
                    )
                } catch {
                    if isAccessing { folder.stopAccessingSecurityScopedResource() }
                    throw error
                }
                // Kept open until the undo is no longer possible: putting the folder back at its place
                // needs this permission.
                accessedFolder = isAccessing ? folder : nil
            }
        }

        // 2. The window shows another gallery first, so no view keeps a deleted one on screen.
        let wasSelected = selectedGalleryId() == gallery.id
        if wasSelected { selectGallery(Self.neighbour(of: gallery.id, in: galleries)) }

        // 3. The catalogue. If that fails, the folder goes back where it was.
        let snapshot: GallerySnapshot
        do {
            snapshot = try await store.removeGallery(id: gallery.id)
        } catch {
            if let trashed { _ = await GalleryFolderTrasher.restore(trashed) }
            accessedFolder?.stopAccessingSecurityScopedResource()
            if wasSelected { selectGallery(gallery.id) }
            throw error
        }

        // 4. What « Annuler » needs, for the undo period.
        purgeQueue.add(galleryId: gallery.id, photoIds: snapshot.photos.map(\.id))
        let record = DeletionRecord(snapshot: snapshot, trashedFolder: trashed, accessedFolder: accessedFolder)
        records[gallery.id] = record
        registerUndo(record)
        record.expiry = Task { [weak self, undoPeriod] in
            try? await Task.sleep(for: undoPeriod)
            guard !Task.isCancelled else { return }
            await self?.finish(galleryId: gallery.id)
        }

        self.request = nil
        folderCheck = nil
        alsoTrashFolder = false
        show(GalleryDeletionBanner(galleryId: gallery.id, galleryName: gallery.name, kind: .deleted(folderTrashed: trashed != nil)))
    }

    /// The gallery shown after `galleryId` is deleted: the next one in the sidebar (newest first),
    /// otherwise the one above, nil when it was the only one.
    nonisolated static func neighbour(of galleryId: UUID, in galleries: [GalleryLocation]) -> UUID? {
        let sorted = galleries.sorted { $0.createdAt > $1.createdAt }
        guard let index = sorted.firstIndex(where: { $0.id == galleryId }) else { return nil }
        if index + 1 < sorted.count { return sorted[index + 1].id }
        return index > 0 ? sorted[index - 1].id : nil
    }

    private func inspectFolder(galleryId: UUID) async -> FolderTrashCheck? {
        guard let galleries = try? await store.galleryLocations(),
              let gallery = galleries.first(where: { $0.id == galleryId })
        else { return nil }
        let others = galleries.filter { $0.id != galleryId }.map { FolderTrashRules.GalleryFolder(name: $0.name, path: $0.folderPath) }
        return await GalleryFolderTrasher.inspect(
            gallery, availability: galleryAvailability(galleryId), otherGalleries: others, protectedPaths: protectedPaths()
        )
    }

    // MARK: - Undo

    /// Whether the deletion of this gallery can still be undone.
    func canUndo(galleryId: UUID) -> Bool {
        records[galleryId].map { !$0.isUndoing } ?? false
    }

    /// Where the folder of a deleted gallery went, while the undo is possible (used by the tests).
    func trashedFolder(of galleryId: UUID) -> TrashedFolder? {
        records[galleryId]?.trashedFolder
    }

    /// « Annuler » in the banner (⌘Z goes through the undo manager, which calls the same code).
    func undo(galleryId: UUID) {
        guard let record = records[galleryId], !record.isUndoing else { return }
        // Not on ⌘Z any more either.
        record.undoManager?.removeAllActions(withTarget: record)
        startUndo(record)
    }

    private func registerUndo(_ record: DeletionRecord) {
        guard let undoManager else { return }
        record.undoManager = undoManager
        // An explicit group: the undo is registered after an `await`, outside the key press or click
        // that started it (see « Piège des tests avec annulation » in macos/CLAUDE.md).
        undoManager.beginUndoGrouping()
        // `registerUndo` keeps a closure that puts the gallery back (like pushing an inverse function
        // on a history stack). No redo is registered: deleting again needs a new confirmation.
        undoManager.registerUndo(withTarget: record) { [weak self] record in
            self?.startUndo(record)
        }
        undoManager.setActionName(String(localized: "Suppression de « \(record.snapshot.name) »"))
        undoManager.endUndoGrouping()
    }

    private func startUndo(_ record: DeletionRecord) {
        guard !record.isUndoing, records[record.snapshot.id] === record else { return }
        record.isUndoing = true
        record.expiry?.cancel()
        let galleryId = record.snapshot.id
        undoTasks[galleryId] = Task {
            defer { undoTasks[galleryId] = nil }
            // The folder first: the gallery then finds its files at once.
            var problem: FolderRestoreProblem?
            if let trashed = record.trashedFolder {
                problem = await GalleryFolderTrasher.restore(trashed)
            }
            do {
                try await store.restoreGallery(record.snapshot)
            } catch {
                errorMessage = error.localizedDescription
                record.isUndoing = false
                // Still undoable from the banner until the end of the period.
                record.expiry = Task { [weak self, undoPeriod] in
                    try? await Task.sleep(for: undoPeriod)
                    guard !Task.isCancelled else { return }
                    await self?.finish(galleryId: galleryId)
                }
                return
            }
            records[galleryId] = nil
            purgeQueue.remove(galleryId: galleryId)
            record.close()
            selectGallery(galleryId)
            show(GalleryDeletionBanner(galleryId: galleryId, galleryName: record.snapshot.name, kind: .restored(problem: problem?.message)))
        }
    }

    // MARK: - End of the undo period

    /// The undo is no longer possible: the cached thumbnails go, the folder's permission is given back.
    func finish(galleryId: UUID) async {
        guard let record = records[galleryId], !record.isUndoing else { return }
        records[galleryId] = nil
        record.expiry?.cancel()
        record.undoManager?.removeAllActions(withTarget: record)
        record.close()
        if banner?.galleryId == galleryId, banner?.canUndo == true { hideBanner() }
        await purgeThumbnails(galleryId: galleryId, photoIds: record.snapshot.photos.map(\.id))
    }

    /// At launch: the thumbnails of galleries deleted before the app quit (or crashed).
    func purgeLeftovers() async {
        for (galleryId, photoIds) in purgeQueue.pending() where records[galleryId] == nil {
            await purgeThumbnails(galleryId: galleryId, photoIds: photoIds)
        }
    }

    /// When the app quits: every undo ends now. Synchronous, the app will not wait for a task.
    func finishAllNow() {
        for (galleryId, record) in records where !record.isUndoing {
            record.expiry?.cancel()
            record.close()
            cache.remove(record.snapshot.photos.map(\.id))
            purgeQueue.remove(galleryId: galleryId)
        }
        records.removeAll()
    }

    /// Never removes the thumbnail of a photo that is in the catalogue (a gallery put back meanwhile).
    private func purgeThumbnails(galleryId: UUID, photoIds: [UUID]) async {
        guard let existing = try? await store.existingPhotoIds(among: photoIds) else { return }
        cache.remove(photoIds.filter { !existing.contains($0) })
        purgeQueue.remove(galleryId: galleryId)
    }

    // MARK: - Banner

    func hideBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    private func show(_ banner: GalleryDeletionBanner) {
        self.banner = banner
        // VoiceOver says it, like an `aria-live` region.
        AccessibilityNotification.Announcement(banner.announcement).post()
        bannerTask?.cancel()
        // With VoiceOver, the banner stays until closed: there is time to reach « Annuler ».
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        bannerTask = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled, self?.banner == banner else { return }
            self?.banner = nil
        }
    }

    // MARK: - Tests and renders

    /// Waits for the running deletion and undos (used by the tests).
    func waitUntilIdle() async {
        await inspectTask?.value
        while let task = deleteTask ?? undoTasks.values.first {
            await task.value
        }
    }

    /// Shows the window or the banner in a given state, for the interface renders only.
    func showForRenders(request: GalleryDeletionRequest?, folderCheck: FolderTrashCheck?, alsoTrashFolder: Bool = false, banner: GalleryDeletionBanner? = nil) {
        self.request = request
        self.folderCheck = folderCheck
        self.alsoTrashFolder = alsoTrashFolder
        self.banner = banner
    }

    // MARK: - Write access

    static func askForWriteAccess(_ gallery: GalleryLocation) -> URL? {
        GalleryWriteAccess.askUser(
            for: gallery,
            message: String(localized: "Pour mettre le dossier « \(gallery.name) » à la corbeille, LinkLens a besoin de votre accord. Seul ce dossier sera déplacé, et vous pourrez l'en sortir.")
        )
    }
}

/// One deletion that can still be undone. A class, because the undo manager needs an object to
/// attach the undo to (and to remove it from at the end of the period).
@MainActor
private final class DeletionRecord {
    let snapshot: GallerySnapshot
    let trashedFolder: TrashedFolder?
    /// The folder's read-write permission, kept until the undo is no longer possible.
    private var accessedFolder: URL?
    weak var undoManager: UndoManager?
    var expiry: Task<Void, Never>?
    var isUndoing = false

    init(snapshot: GallerySnapshot, trashedFolder: TrashedFolder?, accessedFolder: URL?) {
        self.snapshot = snapshot
        self.trashedFolder = trashedFolder
        self.accessedFolder = accessedFolder
    }

    func close() {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
    }
}
