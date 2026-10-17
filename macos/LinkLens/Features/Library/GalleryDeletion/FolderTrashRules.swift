import Foundation

/// Why « Mettre aussi le dossier à la corbeille » cannot be ticked. The message says it in plain words.
enum FolderTrashBlock: Sendable, Equatable {
    /// F9: the disk holding the folder is not plugged in.
    case diskDisconnected(volumeName: String)
    /// Moved, renamed, already in the trash, or LinkLens lost the permission to read it.
    case folderMissing
    /// Another gallery's folder is inside this one (or it is the very same folder).
    case containsGallery(name: String)
    /// This folder is inside another gallery's folder.
    case insideGallery(name: String)
    /// A folder of the Mac itself: the home folder, Bureau, Images, Téléchargements, the import location…
    case protectedLocation(name: String)
    /// A whole disk.
    case volumeRoot(name: String)
    /// The folder's content could not be listed.
    case unreadable
    /// The folder is not where it was when the window opened.
    case folderMoved

    var message: String {
        switch self {
        case .diskDisconnected(let volumeName):
            String(localized: "Le disque « \(volumeName) » n'est pas branché. Branchez-le pour mettre aussi le dossier à la corbeille, ou supprimez seulement la galerie.")
        case .folderMissing:
            String(localized: "Le dossier est introuvable : il a peut-être été déplacé, renommé ou déjà mis à la corbeille.")
        case .containsGallery(let name):
            String(localized: "Ce dossier contient aussi la galerie « \(name) » : il l'emporterait avec lui. Supprimez seulement la galerie, ou rangez les dossiers autrement dans le Finder.")
        case .insideGallery(let name):
            String(localized: "Ce dossier fait partie du dossier de la galerie « \(name) » : le mettre à la corbeille lui retirerait des photos.")
        case .protectedLocation(let name):
            String(localized: "« \(name) » est un dossier important de votre Mac : LinkLens ne le met jamais à la corbeille.")
        case .volumeRoot(let name):
            String(localized: "« \(name) » est un disque entier : LinkLens ne le met jamais à la corbeille.")
        case .unreadable:
            String(localized: "LinkLens n'arrive pas à lire le contenu de ce dossier : il restera à sa place.")
        case .folderMoved:
            String(localized: "Le dossier a changé de place depuis l'ouverture de cette fenêtre : il restera où il est. Fermez la fenêtre et recommencez.")
        }
    }
}

/// The safeguards of « Mettre aussi le dossier à la corbeille », kept pure (plain paths in, a decision
/// out) so each one is tested without touching a real folder.
///
/// The rule of thumb: when in doubt, the folder stays where it is. Only the gallery's own folder can
/// go (for a card import, the session folder « 2026-09-20 Mariage », never the year folder above it,
/// which is not the gallery's folder), and never one that holds or belongs to another gallery.
enum FolderTrashRules {
    /// A gallery folder as the rules see it.
    struct GalleryFolder: Sendable, Equatable {
        var name: String
        var path: String
    }

    /// The folders that never go to the trash, nor any folder that contains one of them: the system's
    /// folders, the user's home and its standard folders, iCloud Drive, plus `extra` (the default
    /// location of card imports, which holds every year folder).
    static func protectedPaths(home: String, extra: [String] = []) -> [String] {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let system = ["/", "/Users", "/Users/Shared", "/Volumes", "/Applications", "/System", "/Library", "/private", "/usr", "/opt", "/cores"]
        let standard = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Library", "Applications", "Sites"]
            .map { "\(home)/\($0)" }
        let iCloud = ["\(home)/Library/Mobile Documents", "\(home)/Library/Mobile Documents/com~apple~CloudDocs"]
        return system + [home] + standard + iCloud + extra
    }

    /// Nil when the folder may go to the trash, otherwise why it must stay.
    ///
    /// - `isVolumeRoot`: the folder is the top of a disk (read from the disk itself; a path right under
    ///   /Volumes counts too).
    /// - `otherGalleries`: every other gallery of the catalogue.
    static func block(
        folderPath: String,
        isVolumeRoot: Bool,
        otherGalleries: [GalleryFolder],
        protectedPaths: [String]
    ) -> FolderTrashBlock? {
        let path = comparable(folderPath)
        let standardized = (folderPath as NSString).standardizingPath
        if isVolumeRoot || GalleryAvailability.externalMountPath(of: standardized) == standardized {
            return .volumeRoot(name: (standardized as NSString).lastPathComponent)
        }
        // The folder itself, or one of its parents (trashing « /Users/chris » would take « Images » along).
        if protectedPaths.map(comparable).contains(where: { $0 == path || isInside($0, path) }) {
            return .protectedLocation(name: (folderPath as NSString).lastPathComponent)
        }
        for other in otherGalleries {
            let otherPath = comparable(other.path)
            if otherPath == path || isInside(otherPath, path) {
                return .containsGallery(name: other.name)
            }
            if isInside(path, otherPath) {
                return .insideGallery(name: other.name)
            }
        }
        return nil
    }

    /// True when `path` is strictly inside `folder`.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let folder = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(folder)
    }

    /// A form of the path in which two spellings of the same folder are equal: the Mac's disks ignore
    /// case (« Photos » = « photos ») and accents may be stored composed or not (« Forêt »).
    /// Comparing more loosely than the disk only blocks more, never less.
    static func comparable(_ path: String) -> String {
        var path = (path as NSString).standardizingPath.precomposedStringWithCanonicalMapping.lowercased()
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
