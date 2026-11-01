import Foundation

/// One photo to put in the trash (or to take out of LinkLens), as plain values.
struct PhotoTrashItem: Sendable, Equatable, Identifiable {
    var photoId: UUID
    /// Path inside the gallery's folder, as stored in the catalogue.
    var relativePath: String
    /// Size read at indexing time: a file of another size was changed or replaced since.
    var fileSize: Int64
    var isVideo = false
    /// Marked while the disk was unplugged: no stamp could be read then, so a size other than the
    /// catalogue's is reported as « changed since the import ».
    var isPendingTrash = false

    var id: UUID { photoId }
    var fileName: String { (relativePath as NSString).lastPathComponent }
}

/// Puts one file in the trash and says where it went.
///
/// A `protocol` describes what a type can do without saying how, like a TypeScript `interface`: the app
/// passes `FinderTrash`, the tests pass a trash that refuses, as an exFAT disk or a network volume may.
protocol FileTrashing: Sendable {
    /// Moves the file to the trash. Returns where it went, nil if the system did not say.
    func trashItem(at url: URL) throws -> URL?
}

/// The Finder's trash: what « Placer dans la corbeille » does.
struct FinderTrash: FileTrashing {
    func trashItem(at url: URL) throws -> URL? {
        // `&resulting` passes the variable by reference: `trashItem` fills it with where the file went.
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// A photo left where it was, and why.
struct SkippedPhoto: Sendable, Equatable, Identifiable {
    var item: PhotoTrashItem
    var reason: TrashSkipReason

    var id: UUID { item.photoId }
}

/// A burst whose best photo went to the trash: another photo got the star (`promotedId`).
struct PromotedCover: Sendable, Equatable {
    var promotedId: UUID
    /// The best photo that left. « Annuler » gives the star back only if it comes back.
    var replacedId: UUID
}

struct PhotoTrashOutcome: Sendable, Equatable {
    var trashed: [TrashedFile]
    var skipped: [SkippedPhoto]
    var promotedCovers: [PromotedCover]
    /// « Annuler » in the progress pill: the photos not reached yet were not touched.
    var notReached: [PhotoTrashItem] = []

    var wasCancelled: Bool { !notReached.isEmpty }
}

/// What « Retirer seulement de LinkLens » removed from the catalogue (the files stay where they are).
struct LibraryRemoval: Sendable, Equatable {
    var snapshots: [PhotoSnapshot]
    var promotedCovers: [PromotedCover]
}

/// Puts photos of a gallery in the trash, never deletes a file for good. Right before each move the file
/// is checked again: still inside the gallery's folder, a regular file (not a link), the size of the
/// catalogue, and the size and date read when the confirmation window opened. Any doubt: it stays.
///
/// « Annuler » goes through `DuplicateTrasher.restore` (F5), which checks the fingerprint and never puts
/// a file back over another one.
struct PhotoTrasher: Sendable {
    let store: LibraryStore
    var trash: any FileTrashing = FinderTrash()
    /// Photos removed from the catalogue per save, so a thousand photos make a few short transactions.
    var batchSize = 500

    /// Size and date of each file, read when the confirmation window opens. Only reads. A missing file
    /// has no stamp (it will be skipped as missing).
    @concurrent
    static func stamps(of items: [PhotoTrashItem], in folder: URL) async -> [UUID: FileStamp] {
        var stamps: [UUID: FileStamp] = [:]
        for item in items {
            if Task.isCancelled { break }
            if case .ready(_, let stamp) = check(item, in: folder, expected: nil) {
                stamps[item.photoId] = stamp
            }
        }
        return stamps
    }

    /// The result of the last checks on one file.
    enum Check: Equatable {
        case ready(URL, FileStamp)
        case skip(TrashSkipReason)
    }

    /// Every check made right before moving a file. `expected`: its stamp when the window opened.
    static func check(_ item: PhotoTrashItem, in folder: URL, expected: FileStamp?) -> Check {
        let components = item.relativePath.split(separator: "/")
        guard !item.relativePath.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            return .skip(.outsideGallery)
        }
        let url = folder.appending(path: item.relativePath)
        // Links followed, the folder holding the file must be the gallery's folder or one inside it.
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            return .skip(.outsideGallery)
        }
        // Nil for a missing file, but also for a folder or a link: never followed, never moved.
        guard let stamp = FileStamp.read(url) else { return .skip(.missing) }
        // The catalogue keeps the size read at import, not the modification date: for a photo marked
        // while its disk was away, the size is the only thing to compare with.
        guard stamp.size == item.fileSize else { return .skip(item.isPendingTrash ? .changedSinceImport : .notIdentical) }
        guard expected == nil || expected == stamp else { return .skip(.notIdentical) }
        return .ready(url, stamp)
    }

    /// Moves the files to the trash, then removes their photos from the catalogue.
    ///
    /// - `folder`: the gallery's folder, opened read-write by the caller.
    /// - `stamps`: read by `stamps(of:in:)` when the window opened.
    /// - `onProgress`: told how many files were looked at, on the main actor.
    ///
    /// Stops early when the task is cancelled: what went to the trash still leaves the catalogue (and can
    /// be put back), the rest is not touched.
    @concurrent
    func moveToTrash(
        _ items: [PhotoTrashItem],
        galleryId: UUID,
        folder: URL,
        stamps: [UUID: FileStamp],
        onProgress: @escaping @MainActor @Sendable (Int) -> Void = { _ in }
    ) async throws -> PhotoTrashOutcome {
        var moved: [(item: PhotoTrashItem, trashURL: URL, stamp: FileStamp)] = []
        var skipped: [SkippedPhoto] = []
        var notReached: [PhotoTrashItem] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                notReached = Array(items[index...])
                break
            }
            switch Self.check(item, in: folder, expected: stamps[item.photoId]) {
            case .skip(let reason):
                skipped.append(SkippedPhoto(item: item, reason: reason))
            case .ready(let url, let stamp):
                do {
                    if let trashURL = try trash.trashItem(at: url) {
                        moved.append((item, trashURL, stamp))
                    } else {
                        // Moved, but the system did not say where: it can still be put back from the Finder.
                        skipped.append(SkippedPhoto(item: item, reason: .failed(String(localized: "Mis à la corbeille, mais LinkLens ne pourra pas l'en sortir."))))
                    }
                } catch {
                    // Never a permanent deletion instead: the file stays, the user decides.
                    skipped.append(SkippedPhoto(item: item, reason: .trashRefused(error.localizedDescription)))
                }
            }
            await onProgress(index + 1)
        }

        // The catalogue follows the files. If that fails, the files go back where they were.
        let removal: LibraryRemoval
        do {
            removal = try await removeFromCatalogue(moved.map(\.item.photoId), galleryId: galleryId)
        } catch {
            for file in moved {
                try? FileManager.default.moveItem(at: file.trashURL, to: folder.appending(path: file.item.relativePath))
            }
            throw error
        }
        let snapshotsById = Dictionary(uniqueKeysWithValues: removal.snapshots.map { ($0.id, $0) })
        let trashed = moved.compactMap { file in
            snapshotsById[file.item.photoId].map {
                TrashedFile(galleryId: galleryId, photo: $0, trashURL: file.trashURL, fingerprint: .stamp(file.stamp))
            }
        }
        return PhotoTrashOutcome(trashed: trashed, skipped: skipped, promotedCovers: removal.promotedCovers, notReached: notReached)
    }

    /// Removes the photos from the catalogue (the files are not touched here), by batches, then gives a
    /// new best photo to each burst that lost its own. « Retirer seulement de LinkLens » uses it alone.
    ///
    /// All or nothing: if a batch fails, the batches already removed are put back, so the catalogue still
    /// matches the files (the caller then puts the files back where they were).
    func removeFromCatalogue(_ photoIds: [UUID], galleryId: UUID) async throws -> LibraryRemoval {
        var snapshots: [PhotoSnapshot] = []
        do {
            for start in stride(from: 0, to: photoIds.count, by: batchSize) {
                let batch = Array(photoIds[start..<min(start + batchSize, photoIds.count)])
                snapshots += try await store.removePhotos(ids: batch)
            }
        } catch {
            if !snapshots.isEmpty { try? await store.restorePhotos(snapshots, galleryId: galleryId) }
            throw error
        }
        // The bursts whose best photo (the AI's) left. Only a missing star if this fails: not worth an error.
        let lostCovers = snapshots.filter { $0.isBestOfBurst && $0.burstNumber != nil }
        let promoted = (try? await store.promoteBurstCovers(galleryId: galleryId, burstNumbers: Set(lostCovers.compactMap(\.burstNumber)))) ?? [:]
        let covers = lostCovers.compactMap { snapshot in
            snapshot.burstNumber.flatMap { promoted[$0] }.map { PromotedCover(promotedId: $0, replacedId: snapshot.id) }
        }
        return LibraryRemoval(snapshots: snapshots, promotedCovers: covers)
    }
}
