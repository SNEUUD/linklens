import AppKit
import Observation

/// The last deletion, kept until it is undone or replaced by another one.
struct TrashRecord: Sendable, Equatable {
    var files: [TrashedFile]
    var bytes: Int64
}

/// Drives "Doublons": the search, the copy kept in each group, the move to the trash after
/// confirmation, and "Annuler". Lives as long as the app, so the undo survives closing the window.
@MainActor
@Observable
final class DuplicatesController {
    var errorMessage: String?
    private(set) var report: DuplicateReport?
    private(set) var progress: DuplicateScanProgress?
    private(set) var lastTrash: TrashRecord?
    /// Message shown after a deletion or an undo.
    private(set) var notice: String?
    /// Files left in place by the last deletion or undo, with the reason.
    private(set) var skippedFiles: [SkippedFile] = []
    /// Group id → copy the user chose to keep instead of the proposal.
    private var keptOverrides: [String: UUID] = [:]
    /// Groups the user unticked: nothing in them is moved.
    private var excludedGroups: Set<String> = []

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let scanner: DuplicateScanner
    @ObservationIgnored private let trasher: DuplicateTrasher
    /// Asks the user to allow changes in a gallery folder. Returns the folder chosen, or nil if refused.
    @ObservationIgnored private let requestWriteAccess: @MainActor (GalleryLocation) -> URL?
    /// Whether a gallery's disk is plugged in (F9), set by the app from `GalleryAvailabilityMonitor`.
    /// A closure stored in a property, like passing a function prop in React. The views calling
    /// `selections` still redraw when the monitor changes: SwiftUI tracks what the closure reads.
    @ObservationIgnored var galleryAvailability: @MainActor (UUID) -> GalleryAvailability = { _ in .available }
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var trashTask: Task<Void, Never>?

    private(set) var isScanning = false
    private(set) var isMovingFiles = false

    init(store: LibraryStore, requestWriteAccess: @escaping @MainActor (GalleryLocation) -> URL? = DuplicatesController.askForWriteAccess) {
        self.store = store
        scanner = DuplicateScanner(store: store)
        trasher = DuplicateTrasher(store: store)
        self.requestWriteAccess = requestWriteAccess
    }

    // MARK: - Search

    func scan() {
        guard !isScanning, !isMovingFiles else { return }
        isScanning = true
        scanTask = Task {
            do {
                report = try await scanner.scan { [weak self] progress in
                    self?.progress = progress
                }
            } catch is CancellationError {
                // The fingerprints computed so far are saved: the next search goes faster.
            } catch {
                errorMessage = error.localizedDescription
            }
            progress = nil
            isScanning = false
            scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Choices

    func keptPhotoId(in group: DuplicateGroup) -> UUID {
        keptOverrides[group.id] ?? group.proposal.photoId
    }

    /// True when the copy kept is the one proposed (its reason is then shown).
    func keepsProposal(in group: DuplicateGroup) -> Bool {
        keptPhotoId(in: group) == group.proposal.photoId
    }

    func keep(_ photoId: UUID, in group: DuplicateGroup) {
        keptOverrides[group.id] = photoId == group.proposal.photoId ? nil : photoId
    }

    func isIncluded(_ group: DuplicateGroup) -> Bool {
        !excludedGroups.contains(group.id)
    }

    func setIncluded(_ isIncluded: Bool, _ group: DuplicateGroup) {
        if isIncluded {
            excludedGroups.remove(group.id)
        } else {
            excludedGroups.insert(group.id)
        }
    }

    /// What "Mettre à la corbeille" would do with the current choices. Copies on an unplugged disk
    /// stay where they are (F9); a group whose kept copy is on one is left alone, since the kept copy
    /// must be read again before anything moves.
    var selections: [TrashSelection] {
        (report?.groups ?? []).filter(isIncluded).compactMap { group in
            let keptId = keptPhotoId(in: group)
            guard let keep = group.copies.first(where: { $0.photoId == keptId }), isAvailable(keep) else { return nil }
            let trash = group.copies.filter { $0.photoId != keptId && isAvailable($0) }
            return trash.isEmpty ? nil : TrashSelection(sha256: group.sha256, keep: keep, trash: trash)
        }
    }

    /// Why this copy cannot be moved or used as the kept copy now, nil when it can.
    func availability(of copy: DuplicateCopy) -> GalleryAvailability {
        galleryAvailability(copy.galleryId)
    }

    private func isAvailable(_ copy: DuplicateCopy) -> Bool {
        availability(of: copy).canUseOriginals
    }

    var selectedCopyCount: Int { selections.reduce(0) { $0 + $1.trash.count } }
    var selectedBytes: Int64 { selections.reduce(0) { $0 + $1.trash.reduce(0) { $0 + $1.fileSize } } }

    // MARK: - Trash and undo

    /// Called once the user confirmed. Asks for write access to the folders that need it first.
    func moveSelectionToTrash() {
        let selections = selections
        guard !selections.isEmpty, !isScanning, !isMovingFiles else { return }
        isMovingFiles = true
        notice = nil
        skippedFiles = []
        trashTask = Task {
            do {
                let galleries = try await store.galleryLocations()
                let needed = Set(selections.flatMap { $0.trash.map(\.galleryId) })
                let access = await openForWriting(galleries.filter { needed.contains($0.id) })
                defer { access.close() }
                if !access.folders.isEmpty {
                    let outcome = try await trasher.moveToTrash(selections, galleries: galleries, writableFolders: access.folders)
                    if !outcome.trashed.isEmpty {
                        lastTrash = TrashRecord(files: outcome.trashed, bytes: outcome.trashedBytes)
                        notice = String(localized: "Copies mises à la corbeille : \(outcome.trashed.count) (\(outcome.trashedBytes.formatted(.byteCount(style: .file)))).")
                    }
                    skippedFiles = outcome.skipped
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isMovingFiles = false
            trashTask = nil
            scan()
        }
    }

    /// Puts the files of the last deletion back where they were, and their photos in their galleries.
    func undoLastTrash() {
        guard let record = lastTrash, !isScanning, !isMovingFiles else { return }
        isMovingFiles = true
        notice = nil
        skippedFiles = []
        trashTask = Task {
            do {
                let galleries = try await store.galleryLocations()
                let needed = Set(record.files.map(\.galleryId))
                let access = await openForWriting(galleries.filter { needed.contains($0.id) })
                defer { access.close() }
                if !access.folders.isEmpty {
                    let outcome = try await trasher.restore(
                        record.files,
                        galleryNames: Dictionary(uniqueKeysWithValues: galleries.map { ($0.id, $0.name) }),
                        writableFolders: access.folders
                    )
                    lastTrash = nil
                    notice = String(localized: "Copies remises à leur place : \(outcome.restored).")
                    skippedFiles = outcome.skipped
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isMovingFiles = false
            trashTask = nil
            scan()
        }
    }

    func dismissNotice() {
        notice = nil
        skippedFiles = []
    }

    /// Waits for the running search or move (used by the tests).
    func waitUntilIdle() async {
        while let task = trashTask ?? scanTask {
            await task.value
        }
    }

    // MARK: - Write access

    /// Folders opened read-write; `close()` gives the access back.
    private struct WriteAccess {
        var folders: [UUID: URL] = [:]
        var accessed: [URL] = []

        func close() {
            for url in accessed { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// The saved read-write bookmark when there is one, otherwise the user is asked (once per folder:
    /// the permission is then saved). A refused folder is left out: its copies stay in place.
    private func openForWriting(_ galleries: [GalleryLocation]) async -> WriteAccess {
        var access = WriteAccess()
        // No folder picker for a disk that is not plugged in: its files are reported as left in place.
        for gallery in galleries where galleryAvailability(gallery.id).canUseOriginals {
            if let bookmark = gallery.writeBookmark,
               let folder = try? FolderBookmark.resolve(bookmark),
               folder.startAccessingSecurityScopedResource() {
                access.folders[gallery.id] = folder
                access.accessed.append(folder)
                continue
            }
            guard let chosen = requestWriteAccess(gallery) else { continue }
            guard FolderBookmark.canonicalPath(of: chosen) == gallery.folderPath else {
                errorMessage = String(localized: "Choisissez le dossier « \(gallery.name) » lui-même pour autoriser LinkLens à y faire le tri.")
                continue
            }
            if let bookmark = try? FolderBookmark.createReadWrite(for: chosen) {
                try? await store.setWriteBookmark(bookmark, galleryId: gallery.id)
            }
            // A folder picked in the panel is open until the app quits; `startAccessing…` may return false.
            if chosen.startAccessingSecurityScopedResource() {
                access.accessed.append(chosen)
            }
            access.folders[gallery.id] = chosen
        }
        return access
    }

    /// The sandbox only lets the app change a folder the user picked: the folder is shown, the user
    /// clicks "Autoriser". `static` because it is used as a default value of `init`.
    static func askForWriteAccess(_ gallery: GalleryLocation) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(filePath: gallery.folderPath, directoryHint: .isDirectory)
        panel.prompt = String(localized: "Autoriser")
        panel.message = String(localized: "Pour mettre des copies en double à la corbeille, LinkLens a besoin de votre accord pour modifier le dossier « \(gallery.name) ». Seules les copies que vous avez confirmées seront déplacées.")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
