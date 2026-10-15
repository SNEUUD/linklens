import Foundation

/// What the user confirmed for one group: the copy kept and the copies to put in the trash.
struct TrashSelection: Sendable, Equatable {
    var sha256: String
    var keep: DuplicateCopy
    var trash: [DuplicateCopy]
}

/// A copy now in the trash, with all it takes to put it back.
struct TrashedFile: Sendable, Equatable {
    var galleryId: UUID
    /// The photo as it was in the catalogue.
    var photo: PhotoSnapshot
    /// Where the Finder put it, as returned by `FileManager.trashItem`.
    var trashURL: URL
    /// Fingerprint of the file: once the trash is emptied, another file may get the same name there.
    var sha256: String
}

/// Why one file was left where it was. Nothing is moved unless every check passes.
enum TrashSkipReason: Sendable, Equatable {
    /// The copy to keep cannot be read: the others are not touched, so a copy always remains.
    case keptCopyUnavailable
    /// The copy to keep changed since the search: the others are not identical any more.
    case keptCopyChanged
    /// This copy changed since the search.
    case notIdentical
    case missing
    case noWriteAccess
    case notInTrash
    /// "Annuler": a file with that name is back at the original place.
    case nameTaken
    case failed(String)

    var message: String {
        switch self {
        case .keptCopyUnavailable: String(localized: "La copie gardée est introuvable : rien n'a été déplacé.")
        case .keptCopyChanged: String(localized: "La copie gardée a changé depuis la recherche : rien n'a été déplacé.")
        case .notIdentical: String(localized: "Ce fichier a changé depuis la recherche.")
        case .missing: String(localized: "Fichier introuvable.")
        case .noWriteAccess: String(localized: "LinkLens n'a pas l'autorisation de modifier ce dossier.")
        case .notInTrash: String(localized: "Le fichier n'est plus dans la corbeille.")
        case .nameTaken: String(localized: "Un autre fichier porte déjà ce nom à cet endroit.")
        case .failed(let reason): reason
        }
    }
}

struct SkippedFile: Sendable, Equatable {
    var galleryName: String
    var relativePath: String
    var reason: TrashSkipReason
}

struct TrashOutcome: Sendable, Equatable {
    var trashed: [TrashedFile]
    var skipped: [SkippedFile]

    var trashedBytes: Int64 { trashed.reduce(0) { $0 + $1.photo.fileSize } }
}

struct RestoreOutcome: Sendable, Equatable {
    var restored: Int
    var skipped: [SkippedFile]
}

/// F5: puts confirmed duplicates in the trash, and back. Never deletes a file for good.
///
/// Before moving a copy, both it and the kept copy are read again: the move only happens if both still
/// have the fingerprint of the group. The kept copy is only read, never modified.
struct DuplicateTrasher: Sendable {
    let store: LibraryStore

    /// - Parameters:
    ///   - galleries: every gallery involved, to read the kept copies.
    ///   - writableFolders: folders opened read-write by the caller, by gallery id. A copy whose gallery
    ///     is missing here is skipped.
    @concurrent
    func moveToTrash(
        _ selections: [TrashSelection],
        galleries: [GalleryLocation],
        writableFolders: [UUID: URL]
    ) async throws -> TrashOutcome {
        var folders = writableFolders
        var openedForReading: [URL] = []
        defer {
            for folder in openedForReading { folder.stopAccessingSecurityScopedResource() }
        }
        func folder(for galleryId: UUID) -> URL? {
            if let folder = folders[galleryId] { return folder }
            guard let gallery = galleries.first(where: { $0.id == galleryId }),
                  let folder = DuplicateScanner.openForReading(gallery)
            else { return nil }
            openedForReading.append(folder)
            folders[galleryId] = folder
            return folder
        }

        var moved: [(copy: DuplicateCopy, trashURL: URL, sha256: String)] = []
        var skipped: [SkippedFile] = []
        for selection in selections {
            func skip(_ copy: DuplicateCopy, _ reason: TrashSkipReason) {
                skipped.append(SkippedFile(galleryName: copy.galleryName, relativePath: copy.relativePath, reason: reason))
            }
            let trash = selection.trash.filter { $0.photoId != selection.keep.photoId }
            guard let keepFolder = folder(for: selection.keep.galleryId) else {
                trash.forEach { skip($0, .keptCopyUnavailable) }
                continue
            }
            let keptHash = try? VerifiedCopier.sha256(of: keepFolder.appending(path: selection.keep.relativePath))
            guard let keptHash else {
                trash.forEach { skip($0, .keptCopyUnavailable) }
                continue
            }
            guard keptHash == selection.sha256 else {
                trash.forEach { skip($0, .keptCopyChanged) }
                continue
            }

            for copy in trash {
                guard let writable = writableFolders[copy.galleryId] else {
                    skip(copy, .noWriteAccess)
                    continue
                }
                let url = writable.appending(path: copy.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    skip(copy, .missing)
                    continue
                }
                guard (try? VerifiedCopier.sha256(of: url)) == selection.sha256 else {
                    skip(copy, .notIdentical)
                    continue
                }
                // `trashItem` does what "Mettre à la corbeille" does in the Finder, and tells where the
                // file went. `&resulting` passes the variable by reference, so the function can fill it.
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                } catch {
                    skip(copy, .failed(error.localizedDescription))
                    continue
                }
                guard let trashURL = resulting as URL? else {
                    // Moved, but the system did not say where: it can still be put back from the Finder.
                    skip(copy, .failed(String(localized: "Mis à la corbeille, mais LinkLens ne pourra pas l'en sortir.")))
                    continue
                }
                moved.append((copy, trashURL, selection.sha256))
            }
        }

        // The catalogue follows the files. If that fails, the files go back where they were.
        let snapshots: [PhotoSnapshot]
        do {
            snapshots = try await store.removePhotos(ids: moved.map(\.copy.photoId))
        } catch {
            for (copy, trashURL, _) in moved {
                if let folder = writableFolders[copy.galleryId] {
                    try? FileManager.default.moveItem(at: trashURL, to: folder.appending(path: copy.relativePath))
                }
            }
            throw error
        }
        let snapshotsById = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        let trashed = moved.compactMap { copy, trashURL, sha256 in
            snapshotsById[copy.photoId].map { TrashedFile(galleryId: copy.galleryId, photo: $0, trashURL: trashURL, sha256: sha256) }
        }
        return TrashOutcome(trashed: trashed, skipped: skipped)
    }

    /// "Annuler": takes the files out of the trash, back to their place, and restores their photos.
    /// A file is never put back over another one.
    @concurrent
    func restore(
        _ files: [TrashedFile],
        galleryNames: [UUID: String],
        writableFolders: [UUID: URL]
    ) async throws -> RestoreOutcome {
        var restored: [UUID: [PhotoSnapshot]] = [:]
        var skipped: [SkippedFile] = []
        for file in files {
            func skip(_ reason: TrashSkipReason) {
                skipped.append(SkippedFile(galleryName: galleryNames[file.galleryId] ?? "", relativePath: file.photo.relativePath, reason: reason))
            }
            guard let folder = writableFolders[file.galleryId] else {
                skip(.noWriteAccess)
                continue
            }
            let destination = folder.appending(path: file.photo.relativePath)
            // Same name is not enough: the trash may have been emptied and another file put there since.
            guard FileManager.default.fileExists(atPath: file.trashURL.path),
                  (try? VerifiedCopier.sha256(of: file.trashURL)) == file.sha256
            else {
                skip(.notInTrash)
                continue
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                skip(.nameTaken)
                continue
            }
            do {
                // `moveItem` never replaces an existing file: it fails instead.
                try FileManager.default.moveItem(at: file.trashURL, to: destination)
            } catch {
                skip(.failed(error.localizedDescription))
                continue
            }
            restored[file.galleryId, default: []].append(file.photo)
        }
        for (galleryId, photos) in restored {
            try await store.restorePhotos(photos, galleryId: galleryId)
        }
        return RestoreOutcome(restored: restored.values.reduce(0) { $0 + $1.count }, skipped: skipped)
    }
}
