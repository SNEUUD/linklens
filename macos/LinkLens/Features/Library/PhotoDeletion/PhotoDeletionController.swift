import AppKit
import Observation
import SwiftUI

/// The photos the confirmation window is about, as plain values (never the `@Model` objects, which
/// leave the catalogue while the window closes).
struct PhotoDeletionRequest: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        /// The selection of the grid or the table (⌘⌫, right-click, « Galerie » menu).
        case selection
        /// Every photo whose verdict shown is « Rejeter » (the user's choice, otherwise the AI's).
        case rejected
    }

    var id = UUID()
    var galleryId: UUID
    var galleryName: String
    var kind: Kind
    /// In display order: the window shows the first ones.
    var items: [PhotoTrashItem]

    var count: Int { items.count }
    var videoCount: Int { items.filter(\.isVideo).count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.fileSize } }
    /// The photos shown as thumbnails in the window.
    var previews: [PhotoTrashItem] { Array(items.prefix(5)) }

    /// Every photo of the gallery that the « Rejeter » filter shows: the user's « Rejeter », otherwise
    /// the AI's. `photos` in display order.
    @MainActor
    static func rejected(in gallery: Gallery, photos: [Photo]) -> PhotoDeletionRequest {
        PhotoDeletionRequest(galleryId: gallery.id, galleryName: gallery.name, kind: .rejected, items: photos.filter { $0.verdict == .reject }.map(\.trashItem))
    }
}

extension Photo {
    var trashItem: PhotoTrashItem {
        PhotoTrashItem(photoId: id, relativePath: relativePath, fileSize: fileSize, isVideo: mediaKind == .video)
    }
}

/// After a deletion where some files stayed where they were: which ones, and why. The window then offers
/// « Retirer seulement de LinkLens » for them.
struct PhotoDeletionReport: Sendable, Equatable, Identifiable {
    var id = UUID()
    var galleryId: UUID
    var galleryName: String
    var trashedCount: Int
    var skipped: [SkippedPhoto]
    /// Not reached because « Annuler » was clicked in the progress pill (not touched, still in LinkLens).
    var notReachedCount = 0

    /// The trash said no to at least one file: probably a disk without a trash (exFAT, FAT, network).
    var trashWasRefused: Bool {
        skipped.contains { if case .trashRefused = $0.reason { true } else { false } }
    }
}

/// The glass banner after a deletion (with « Annuler ») and after an undo.
struct PhotoDeletionBanner: Equatable {
    enum Kind: Equatable {
        /// `keptInPlace`: files that stayed where they were (listed in the report).
        case trashed(count: Int, keptInPlace: Int)
        case removedFromLibrary(count: Int)
        /// `problem`: what could not come back, nil when everything did.
        case restored(count: Int, problem: String?)
    }

    /// The deletion « Annuler » undoes; nil after an undo.
    var recordId: UUID?
    var kind: Kind

    var canUndo: Bool { recordId != nil }

    var title: String {
        switch kind {
        case .trashed(let count, _): PhotoDeletionText.trashedTitle(count: count)
        case .removedFromLibrary(let count): PhotoDeletionText.removedTitle(count: count)
        case .restored(let count, _): PhotoDeletionText.restoredTitle(count: count)
        }
    }

    var detail: String? {
        switch kind {
        case .trashed(_, let kept): kept > 0 ? PhotoDeletionText.keptInPlace(kept) : nil
        case .removedFromLibrary: String(localized: "Les fichiers sont restés à leur place.")
        case .restored(_, let problem): problem
        }
    }

    /// What VoiceOver says when the banner appears.
    var announcement: String {
        var parts = [title]
        if let detail { parts.append(detail) }
        if canUndo { parts.append(String(localized: "Commande Z pour annuler.")) }
        // Each part as a sentence, without doubling the full stop of those that already have one.
        return parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }
}

/// Deleting photos inside a gallery: the confirmation window, the move to the trash (with the progress
/// pill for big selections), the report of the files that stayed, « Annuler » (⌘Z and the banner) and,
/// once the undo is no longer possible, the cleaning of the cached thumbnails.
///
/// Lives as long as the app, like `GalleryDeletionController`, so the undo survives a change of gallery.
@MainActor
@Observable
final class PhotoDeletionController {
    /// The confirmation window is shown while this is set.
    private(set) var request: PhotoDeletionRequest?
    /// Size and date of each file, read when the window opened; nil while they are being read.
    private(set) var stamps: [UUID: FileStamp]?
    /// The move to the trash under way: « Mise à la corbeille · 120 sur 1 030 » in the progress pill.
    private(set) var progress: PhotoTrashProgress?
    /// Shown in a window when some files stayed where they were.
    private(set) var report: PhotoDeletionReport?
    /// Shown inside the window while it is open, as an alert otherwise.
    var errorMessage: String?
    private(set) var banner: PhotoDeletionBanner?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let trasher: PhotoTrasher
    @ObservationIgnored private let cache: ThumbnailCache
    @ObservationIgnored private let purgeQueue: ThumbnailPurgeQueue
    @ObservationIgnored private let undoPeriod: Duration
    @ObservationIgnored private let bannerDuration: Duration
    /// Asks the user to allow changes in the folder (the « Autoriser » panel). Nil if refused.
    @ObservationIgnored private let requestWriteAccess: @MainActor (GalleryLocation) -> URL?

    // Set by the app (closures stored in properties, like function props in React).
    /// F9: whether the gallery's disk is plugged in.
    @ObservationIgnored var galleryAvailability: @MainActor (UUID) -> GalleryAvailability = { _ in .available }
    /// True while the gallery is indexed, sorted, exported… : its photos cannot be deleted meanwhile.
    @ObservationIgnored var isBusy: @MainActor (UUID) -> Bool = { _ in false }

    @ObservationIgnored private weak var undoManager: UndoManager?
    /// Deletions that can still be undone, by record id.
    @ObservationIgnored private var records: [UUID: PhotoDeletionRecord] = [:]
    @ObservationIgnored private var inspectTask: Task<Void, Never>?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var undoTasks: [UUID: Task<Void, Never>] = [:]

    init(
        store: LibraryStore,
        trash: any FileTrashing = FinderTrash(),
        cache: ThumbnailCache = .standard,
        purgeQueue: ThumbnailPurgeQueue = .standard,
        undoPeriod: Duration = GalleryDeletionController.standardUndoPeriod,
        bannerDuration: Duration = GalleryDeletionController.standardBannerDuration,
        requestWriteAccess: @escaping @MainActor (GalleryLocation) -> URL? = PhotoDeletionController.askForWriteAccess
    ) {
        self.store = store
        trasher = PhotoTrasher(store: store, trash: trash)
        self.cache = cache
        self.purgeQueue = purgeQueue
        self.undoPeriod = undoPeriod
        self.bannerDuration = bannerDuration
        self.requestWriteAccess = requestWriteAccess
    }

    // MARK: - Confirmation window

    /// Why the photos of this gallery cannot be deleted now, nil when they can.
    func blockReason(galleryId: UUID) -> String? {
        if let help = galleryAvailability(galleryId).help(for: .trash) { return help }
        if isBusy(galleryId) {
            return String(localized: "Attendez la fin de l'indexation, du tri ou de l'export de cette galerie.")
        }
        if progress != nil { return String(localized: "Une mise à la corbeille est déjà en cours.") }
        return nil
    }

    func canRequest(galleryId: UUID) -> Bool {
        request == nil && report == nil && blockReason(galleryId: galleryId) == nil
    }

    /// Opens the confirmation window, then reads the size and date of each file in the background.
    func requestDeletion(_ request: PhotoDeletionRequest, undoManager: UndoManager?) {
        guard !request.items.isEmpty, canRequest(galleryId: request.galleryId) else { return }
        self.request = request
        self.undoManager = undoManager
        stamps = nil
        errorMessage = nil
        inspectTask = Task {
            let read = await readStamps(of: request)
            guard self.request?.id == request.id else { return }
            stamps = read
        }
    }

    /// « Annuler » or Escape: nothing changes.
    func cancel() {
        inspectTask?.cancel()
        request = nil
        stamps = nil
        errorMessage = nil
    }

    /// « Mettre à la corbeille ». Asks for the folder's permission the first time (« Autoriser »), then the
    /// window closes and the progress pill takes over.
    func confirm() {
        guard let request, workTask == nil else { return }
        workTask = Task {
            defer { workTask = nil }
            await trash(request)
        }
    }

    /// « Retirer seulement de LinkLens (garder les fichiers) »: the photos leave the catalogue, the files
    /// stay exactly where they are. Undoable as well.
    func removeFromLibraryOnly() {
        guard let request, workTask == nil else { return }
        let photoIds = request.items.map(\.photoId)
        inspectTask?.cancel()
        self.request = nil
        stamps = nil
        workTask = Task {
            defer { workTask = nil }
            await removeFromLibrary(photoIds, galleryId: request.galleryId, galleryName: request.galleryName)
        }
    }

    /// The report's « Retirer seulement de LinkLens »: the photos whose file stayed in place.
    func removeSkippedFromLibrary() {
        guard let report, workTask == nil else { return }
        self.report = nil
        workTask = Task {
            defer { workTask = nil }
            await removeFromLibrary(report.skipped.map(\.item.photoId), galleryId: report.galleryId, galleryName: report.galleryName)
        }
    }

    func dismissReport() {
        report = nil
    }

    /// « Annuler » in the progress pill: stops after the current file. What already went to the trash
    /// stays undoable.
    func cancelTrashing() {
        workTask?.cancel()
    }

    private func trash(_ request: PhotoDeletionRequest) async {
        errorMessage = nil
        let gallery: GalleryLocation
        do {
            guard let found = try await store.galleryLocations().first(where: { $0.id == request.galleryId }) else {
                throw LibraryError.galleryNotFound
            }
            gallery = found
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Checked again now: the disk may have been unplugged since the window opened.
        if let help = galleryAvailability(gallery.id).help(for: .trash) {
            errorMessage = String(localized: "Rien n'a été déplacé. \(help)")
            return
        }
        let folder: URL
        let isAccessing: Bool
        switch await GalleryWriteAccess.open(gallery, store: store, askUser: requestWriteAccess) {
        case .refused:
            // « Autoriser » closed: nothing happened, the window stays open.
            return
        case .wrongFolder:
            errorMessage = String(localized: "Rien n'a été déplacé : choisissez le dossier « \(gallery.name) » lui-même dans la fenêtre « Autoriser ».")
            return
        case .opened(let opened, let accessing):
            folder = opened
            isAccessing = accessing
        }

        // The window closes: a big selection goes on in the progress pill, the interface stays usable.
        let stamps = self.stamps ?? [:]
        inspectTask?.cancel()
        self.request = nil
        self.stamps = nil
        progress = PhotoTrashProgress(galleryId: gallery.id, completed: 0, total: request.count, startedAt: .now)
        let culledAt = try? await store.culledAt(galleryId: gallery.id)
        let outcome: PhotoTrashOutcome
        do {
            outcome = try await trasher.moveToTrash(request.items, galleryId: gallery.id, folder: folder, stamps: stamps) { [weak self] completed in
                self?.progress?.completed = completed
            }
        } catch {
            progress = nil
            if isAccessing { folder.stopAccessingSecurityScopedResource() }
            errorMessage = String(localized: "Les photos n'ont pas pu être retirées du catalogue (\(error.localizedDescription)). Les fichiers sont revenus à leur place.")
            return
        }
        progress = nil

        if outcome.trashed.isEmpty {
            if isAccessing { folder.stopAccessingSecurityScopedResource() }
        } else {
            // The folder's permission stays open until the undo is no longer possible: putting the
            // files back needs it.
            let record = PhotoDeletionRecord(
                galleryId: gallery.id, galleryName: gallery.name, trashed: outcome.trashed, removedOnly: [],
                promotedCovers: outcome.promotedCovers, culledAt: culledAt, folder: folder, isAccessing: isAccessing
            )
            add(record, actionName: PhotoDeletionText.undoActionName(trashed: outcome.trashed.count))
            show(PhotoDeletionBanner(recordId: record.id, kind: .trashed(count: outcome.trashed.count, keptInPlace: outcome.skipped.count)))
        }
        if !outcome.skipped.isEmpty || outcome.wasCancelled {
            report = PhotoDeletionReport(
                galleryId: gallery.id, galleryName: gallery.name, trashedCount: outcome.trashed.count,
                skipped: outcome.skipped, notReachedCount: outcome.notReached.count
            )
            if !outcome.skipped.isEmpty {
                AccessibilityNotification.Announcement(PhotoDeletionText.keptInPlace(outcome.skipped.count)).post()
            }
        }
    }

    private func removeFromLibrary(_ photoIds: [UUID], galleryId: UUID, galleryName: String) async {
        guard !photoIds.isEmpty else { return }
        let culledAt = try? await store.culledAt(galleryId: galleryId)
        do {
            let removal = try await trasher.removeFromCatalogue(photoIds, galleryId: galleryId)
            guard !removal.snapshots.isEmpty else { return }
            let record = PhotoDeletionRecord(
                galleryId: galleryId, galleryName: galleryName, trashed: [], removedOnly: removal.snapshots,
                promotedCovers: removal.promotedCovers, culledAt: culledAt, folder: nil, isAccessing: false
            )
            add(record, actionName: PhotoDeletionText.undoActionName(removed: removal.snapshots.count))
            show(PhotoDeletionBanner(recordId: record.id, kind: .removedFromLibrary(count: removal.snapshots.count)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the files' size and date through the gallery's read-only permission.
    private func readStamps(of request: PhotoDeletionRequest) async -> [UUID: FileStamp] {
        guard galleryAvailability(request.galleryId).canUseOriginals,
              let gallery = try? await store.galleryLocations().first(where: { $0.id == request.galleryId }),
              let folder = try? FolderBookmark.resolve(gallery.folderBookmark)
        else { return [:] }
        let isAccessing = folder.startAccessingSecurityScopedResource()
        defer { if isAccessing { folder.stopAccessingSecurityScopedResource() } }
        return await PhotoTrasher.stamps(of: request.items, in: folder)
    }

    // MARK: - Undo

    private func add(_ record: PhotoDeletionRecord, actionName: String) {
        records[record.id] = record
        purgeQueue.add(galleryId: record.id, photoIds: record.photoIds)
        if let undoManager {
            record.undoManager = undoManager
            // An explicit group: the undo is registered after an `await`, outside the key press or click
            // that started it (see « Piège des tests avec annulation » in macos/CLAUDE.md).
            undoManager.beginUndoGrouping()
            // No redo: deleting again needs a new confirmation.
            undoManager.registerUndo(withTarget: record) { [weak self] record in
                self?.startUndo(record)
            }
            undoManager.setActionName(actionName)
            undoManager.endUndoGrouping()
        }
        record.expiry = expiryTask(for: record.id)
    }

    private func expiryTask(for recordId: UUID) -> Task<Void, Never> {
        Task { [weak self, undoPeriod] in
            try? await Task.sleep(for: undoPeriod)
            guard !Task.isCancelled else { return }
            await self?.finish(recordId: recordId)
        }
    }

    /// Whether this deletion can still be undone.
    func canUndo(recordId: UUID) -> Bool {
        records[recordId].map { !$0.isUndoing } ?? false
    }

    /// The deletions that can still be undone (used by the tests).
    var undoableRecordIds: [UUID] { Array(records.keys) }

    /// « Annuler » in the banner (⌘Z goes through the undo manager, which calls the same code).
    func undo(recordId: UUID) {
        guard let record = records[recordId], !record.isUndoing else { return }
        record.undoManager?.removeAllActions(withTarget: record)
        startUndo(record)
    }

    private func startUndo(_ record: PhotoDeletionRecord) {
        guard !record.isUndoing, records[record.id] === record else { return }
        record.isUndoing = true
        record.expiry?.cancel()
        undoTasks[record.id] = Task {
            defer { undoTasks[record.id] = nil }
            var restored = 0
            var problems: [SkippedFile] = []
            do {
                if !record.trashed.isEmpty {
                    // Back where they were, after checking the size and date, never over another file.
                    let outcome = try await DuplicateTrasher(store: store).restore(
                        record.trashed, galleryNames: [record.galleryId: record.galleryName],
                        writableFolders: record.folder.map { [record.galleryId: $0] } ?? [:]
                    )
                    restored += outcome.restored
                    problems = outcome.skipped
                }
                if !record.removedOnly.isEmpty {
                    try await store.restorePhotos(record.removedOnly, galleryId: record.galleryId)
                    restored += record.removedOnly.count
                }
                // A burst gets its former best photo back only if that photo came back.
                let back = try await store.existingPhotoIds(among: record.promotedCovers.map(\.replacedId))
                let demoted = record.promotedCovers.filter { back.contains($0.replacedId) }.map(\.promotedId)
                try await store.demoteBurstCovers(ids: demoted, galleryId: record.galleryId, ifCulledAt: record.culledAt)
            } catch {
                errorMessage = error.localizedDescription
                record.isUndoing = false
                // Still undoable from the banner until the end of the period.
                record.expiry = expiryTask(for: record.id)
                return
            }
            records[record.id] = nil
            record.close()
            // Thumbnails of the photos that could not come back go now; the others are found again.
            await purgeThumbnails(key: record.id, photoIds: record.photoIds)
            show(PhotoDeletionBanner(recordId: nil, kind: .restored(count: restored, problem: PhotoDeletionText.restoreProblem(problems))))
        }
    }

    // MARK: - End of the undo period

    /// The undo is no longer possible: the cached thumbnails go, the folder's permission is given back.
    func finish(recordId: UUID) async {
        guard let record = records[recordId], !record.isUndoing else { return }
        records[recordId] = nil
        record.expiry?.cancel()
        record.undoManager?.removeAllActions(withTarget: record)
        record.close()
        if banner?.recordId == recordId { hideBanner() }
        await purgeThumbnails(key: recordId, photoIds: record.photoIds)
    }

    /// When the app quits: every undo ends now. Synchronous, the app will not wait for a task.
    /// (At the next launch, `GalleryDeletionController.purgeLeftovers` cleans what a crash left.)
    func finishAllNow() {
        for (recordId, record) in records where !record.isUndoing {
            record.expiry?.cancel()
            record.close()
            cache.remove(record.photoIds)
            purgeQueue.remove(galleryId: recordId)
        }
        records.removeAll()
    }

    /// Never removes the thumbnail of a photo that is in the catalogue.
    private func purgeThumbnails(key: UUID, photoIds: [UUID]) async {
        guard let existing = try? await store.existingPhotoIds(among: photoIds) else { return }
        cache.remove(photoIds.filter { !existing.contains($0) })
        purgeQueue.remove(galleryId: key)
    }

    // MARK: - Banner

    func hideBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    private func show(_ banner: PhotoDeletionBanner) {
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

    /// Waits for the running reading, deletion and undos (used by the tests).
    func waitUntilIdle() async {
        await inspectTask?.value
        while let task = workTask ?? undoTasks.values.first {
            await task.value
        }
    }

    /// Shows a state, for the interface renders only.
    func showForRenders(
        request: PhotoDeletionRequest? = nil, stamps: [UUID: FileStamp]? = nil, progress: PhotoTrashProgress? = nil,
        report: PhotoDeletionReport? = nil, banner: PhotoDeletionBanner? = nil
    ) {
        self.request = request
        self.stamps = stamps
        self.progress = progress
        self.report = report
        self.banner = banner
    }

    // MARK: - Write access

    static func askForWriteAccess(_ gallery: GalleryLocation) -> URL? {
        GalleryWriteAccess.askUser(
            for: gallery,
            message: String(localized: "Pour mettre des photos de « \(gallery.name) » à la corbeille, LinkLens a besoin de votre accord. Seules les photos que vous avez choisies seront déplacées, et vous pourrez les remettre.")
        )
    }
}

/// « Mise à la corbeille · 120 sur 1 030 ».
struct PhotoTrashProgress: Sendable, Equatable {
    var galleryId: UUID
    var completed: Int
    var total: Int
    var startedAt: Date
}

/// One deletion that can still be undone. A class, because the undo manager needs an object to attach
/// the undo to (and to remove it from at the end of the period).
@MainActor
private final class PhotoDeletionRecord {
    let id = UUID()
    let galleryId: UUID
    let galleryName: String
    let trashed: [TrashedFile]
    /// Photos taken out of LinkLens with their files left in place.
    let removedOnly: [PhotoSnapshot]
    let promotedCovers: [PromotedCover]
    /// The gallery's last sorting when the photos left (see `LibraryStore.demoteBurstCovers`).
    let culledAt: Date?
    /// The folder opened read-write, kept until the undo is no longer possible.
    private(set) var folder: URL?
    private var isAccessing: Bool
    weak var undoManager: UndoManager?
    var expiry: Task<Void, Never>?
    var isUndoing = false

    init(
        galleryId: UUID, galleryName: String, trashed: [TrashedFile], removedOnly: [PhotoSnapshot],
        promotedCovers: [PromotedCover], culledAt: Date?, folder: URL?, isAccessing: Bool
    ) {
        self.galleryId = galleryId
        self.galleryName = galleryName
        self.trashed = trashed
        self.removedOnly = removedOnly
        self.promotedCovers = promotedCovers
        self.culledAt = culledAt
        self.folder = folder
        self.isAccessing = isAccessing
    }

    var photoIds: [UUID] { trashed.map(\.photo.id) + removedOnly.map(\.id) }

    func close() {
        if isAccessing { folder?.stopAccessingSecurityScopedResource() }
        isAccessing = false
        folder = nil
    }
}
