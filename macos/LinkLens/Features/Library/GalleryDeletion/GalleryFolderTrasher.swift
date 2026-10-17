import Foundation

/// The visible files of a folder, with their size and modification date: what the confirmation shows
/// (« 52 fichiers · 1,2 Go ») and the fingerprint that tells, before « Annuler » takes a folder out of
/// the trash, that it really is the folder LinkLens put there. Hidden files (.DS_Store…) are left out:
/// the Finder may add or change them while the folder sits in the trash.
struct FolderContents: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var relativePath: String
        var size: Int64
        var modifiedAt: Date?
    }

    /// Sorted by path, so two listings of the same folder are equal.
    var entries: [Entry]

    var fileCount: Int { entries.count }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }

    /// Lists `folder` and everything under it. Only reads.
    static func read(_ folder: URL) throws -> FolderContents {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                failure = error
                return false
            }
        ) else { throw CocoaError(.fileReadUnknown) }
        var entries: [Entry] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            entries.append(Entry(
                relativePath: String(path.dropFirst(root.path.count + 1)),
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            ))
        }
        if let failure { throw failure }
        return FolderContents(entries: entries.sorted { $0.relativePath < $1.relativePath })
    }

    /// « 52 fichiers · 1,2 Go ». The locale is a parameter so the tests check the French wording.
    func summary(locale: Locale = .current) -> String {
        // `^[…](inflect: true)` writes « 1 fichier » / « 52 fichiers ». It only works through an
        // `AttributedString`: `String(localized:)` would keep the markup as it is.
        let files = String(AttributedString(localized: "^[\(fileCount) fichier](inflect: true)", locale: locale).characters)
        let size = totalBytes.formatted(.byteCount(style: .file).locale(locale))
        return "\(files) · \(size)"
    }
}

/// What the confirmation window knows about the gallery's folder.
struct FolderTrashCheck: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case allowed(FolderContents)
        case blocked(FolderTrashBlock)
    }

    /// The folder as found now (canonical path).
    var folderPath: String
    var outcome: Outcome

    var isAllowed: Bool {
        if case .allowed = outcome { true } else { false }
    }

    var block: FolderTrashBlock? {
        if case .blocked(let block) = outcome { block } else { nil }
    }

    var contents: FolderContents? {
        if case .allowed(let contents) = outcome { contents } else { nil }
    }
}

/// A gallery folder now in the trash, with all it takes to put it back.
struct TrashedFolder: Sendable, Equatable {
    var originalURL: URL
    /// Where the Finder put it, as returned by `FileManager.trashItem`. Nil if the system did not say:
    /// the folder can then only be put back from the Finder.
    var trashURL: URL?
    /// The listing taken right before the move: compared again before taking it out of the trash.
    var contents: FolderContents
}

/// Why « Annuler » left the folder in the trash. The gallery itself still comes back.
enum FolderRestoreProblem: Error, Sendable, Equatable {
    /// The trash was emptied, or what is there now is not the folder LinkLens put there.
    case notInTrash
    /// Something already has the folder's name at its old place: it is never replaced.
    case placeTaken
    case failed(String)

    var message: String {
        switch self {
        case .notInTrash:
            String(localized: "Le dossier n'est plus dans la corbeille : la galerie est revenue sans lui.")
        case .placeTaken:
            String(localized: "Un autre élément porte déjà le nom du dossier à son ancienne place. Le dossier est resté dans la corbeille : remettez-le vous-même depuis le Finder.")
        case .failed(let reason):
            String(localized: "Le dossier est resté dans la corbeille (\(reason)). Remettez-le depuis le Finder : Corbeille, clic droit, « Remettre ».")
        }
    }
}

/// Errors that stop the deletion before anything changed.
enum GalleryDeletionError: LocalizedError, Equatable {
    case folderBlocked(FolderTrashBlock)
    case trashFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderBlocked(let block):
            String(localized: "Rien n'a été supprimé. \(block.message)")
        case .trashFailed(let reason):
            String(localized: "Le dossier n'a pas pu être mis à la corbeille (\(reason)). Rien n'a été supprimé.")
        }
    }
}

/// Puts a gallery's folder in the trash, and back. Never deletes anything for good: `trashItem` does
/// what « Placer dans la corbeille » does in the Finder. Every safeguard of `FolderTrashRules` is
/// checked when the window opens, then again right before the move.
enum GalleryFolderTrasher {
    /// Looks at the folder for the confirmation window. Only reads. `@concurrent`: a big folder on a
    /// slow disk is listed away from the interface.
    @concurrent
    static func inspect(
        _ gallery: GalleryLocation,
        availability: GalleryAvailability,
        otherGalleries: [FolderTrashRules.GalleryFolder],
        protectedPaths: [String]
    ) async -> FolderTrashCheck {
        switch availability {
        case .diskDisconnected(let volumeName):
            return FolderTrashCheck(folderPath: gallery.folderPath, outcome: .blocked(.diskDisconnected(volumeName: volumeName)))
        case .folderMissing:
            return FolderTrashCheck(folderPath: gallery.folderPath, outcome: .blocked(.folderMissing))
        case .available:
            break
        }
        guard let folder = try? FolderBookmark.resolve(gallery.folderBookmark) else {
            return FolderTrashCheck(folderPath: gallery.folderPath, outcome: .blocked(.folderMissing))
        }
        let isAccessing = folder.startAccessingSecurityScopedResource()
        defer { if isAccessing { folder.stopAccessingSecurityScopedResource() } }
        return check(folder, otherGalleries: otherGalleries, protectedPaths: protectedPaths)
    }

    /// Every safeguard, on a folder the caller has access to.
    static func check(_ folder: URL, otherGalleries: [FolderTrashRules.GalleryFolder], protectedPaths: [String]) -> FolderTrashCheck {
        let path = FolderBookmark.canonicalPath(of: folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !FolderBookmark.isInTrash(folder)
        else {
            return FolderTrashCheck(folderPath: path, outcome: .blocked(.folderMissing))
        }
        let isVolumeRoot = (try? folder.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
        if let block = FolderTrashRules.block(
            folderPath: path, isVolumeRoot: isVolumeRoot, otherGalleries: otherGalleries, protectedPaths: protectedPaths
        ) {
            return FolderTrashCheck(folderPath: path, outcome: .blocked(block))
        }
        guard let contents = try? FolderContents.read(folder) else {
            return FolderTrashCheck(folderPath: path, outcome: .blocked(.unreadable))
        }
        return FolderTrashCheck(folderPath: path, outcome: .allowed(contents))
    }

    /// Moves the folder to the trash after checking everything once more.
    ///
    /// - `folder`: the gallery's folder, opened read-write by the caller.
    /// - `expectedPath`: where the confirmation window saw it. If it moved since, nothing happens.
    @concurrent
    static func moveToTrash(
        _ folder: URL,
        expectedPath: String,
        otherGalleries: [FolderTrashRules.GalleryFolder],
        protectedPaths: [String]
    ) async throws -> TrashedFolder {
        let check = check(folder, otherGalleries: otherGalleries, protectedPaths: protectedPaths)
        guard FolderTrashRules.comparable(check.folderPath) == FolderTrashRules.comparable(expectedPath) else {
            throw GalleryDeletionError.folderBlocked(.folderMoved)
        }
        let contents: FolderContents
        switch check.outcome {
        case .blocked(let block): throw GalleryDeletionError.folderBlocked(block)
        case .allowed(let listed): contents = listed
        }
        // `&resulting` passes the variable by reference: `trashItem` fills it with where the folder went.
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: &resulting)
        } catch {
            throw GalleryDeletionError.trashFailed(error.localizedDescription)
        }
        return TrashedFolder(originalURL: folder, trashURL: resulting as URL?, contents: contents)
    }

    /// "Annuler": takes the folder out of the trash, back to its place. Nil when it worked.
    /// Never puts it back over something else, and only if it still holds the same files.
    @concurrent
    static func restore(_ trashed: TrashedFolder) async -> FolderRestoreProblem? {
        guard let trashURL = trashed.trashURL else { return .notInTrash }
        var isDirectory: ObjCBool = false
        // Same name is not enough: the trash may have been emptied and another folder put there since.
        guard FileManager.default.fileExists(atPath: trashURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? FolderContents.read(trashURL)) == trashed.contents
        else { return .notInTrash }
        // `attributesOfItem` also sees a broken alias or link, which `fileExists` would miss.
        if FileManager.default.fileExists(atPath: trashed.originalURL.path)
            || (try? FileManager.default.attributesOfItem(atPath: trashed.originalURL.path)) != nil {
            return .placeTaken
        }
        do {
            // `moveItem` never replaces an existing item: it fails instead.
            try FileManager.default.moveItem(at: trashURL, to: trashed.originalURL)
        } catch {
            return .failed(error.localizedDescription)
        }
        return nil
    }
}
