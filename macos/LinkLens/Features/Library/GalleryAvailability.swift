import Foundation

/// The volume (disk) a gallery folder is on, remembered while it is mounted: once the disk is
/// unplugged, macOS can no longer tell its name.
struct VolumeIdentity: Sendable, Equatable {
    /// Name shown in the Finder, e.g. "Photos 2TB".
    var name: String
    /// Stable id of the volume, nil for the few file systems that have none.
    var uuid: String?

    /// The volume of a reachable file or folder. Nil if macOS cannot tell.
    static func of(_ url: URL) -> VolumeIdentity? {
        guard let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey, .volumeUUIDStringKey]),
              let name = values.volumeLocalizedName ?? values.volumeName
        else { return nil }
        return VolumeIdentity(name: name, uuid: values.volumeUUIDString)
    }
}

/// A volume mounted right now.
struct MountedVolume: Sendable, Equatable {
    var path: String
    var uuid: String?

    static func current() -> [MountedVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        return urls.map { url in
            MountedVolume(
                path: url.standardizedFileURL.path,
                uuid: (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            )
        }
    }
}

/// F9: can the original files of a gallery be read right now?
///
/// An `enum` with associated values is like a TypeScript discriminated union:
/// `{ kind: "available" } | { kind: "diskDisconnected", volumeName: string } | { kind: "folderMissing" }`.
/// When the originals are out of reach, the gallery is still shown from the cached thumbnails,
/// with its AI verdicts; only the actions that read the files wait.
enum GalleryAvailability: Sendable, Equatable {
    case available
    /// The disk holding the folder is not plugged in.
    case diskDisconnected(volumeName: String)
    /// The disk is there (or the folder is on the Mac itself) but the folder is gone: moved to
    /// another disk, deleted, or LinkLens lost the permission to read it.
    case folderMissing

    /// The flag every action reading the originals checks: export (F6), AI sorting (F3),
    /// duplicates to the trash (F5), and publishing (F7) when it exists.
    var canUseOriginals: Bool { self == .available }

    /// Short message shown above the photos and in the sidebar, nil when available.
    var message: String? {
        switch self {
        case .available: nil
        case .diskDisconnected(let volumeName): String(localized: "Disque « \(volumeName) » non connecté")
        case .folderMissing: String(localized: "Dossier introuvable")
        }
    }

    /// What the user can do about it, under the message.
    var advice: String? {
        switch self {
        case .available: nil
        case .diskDisconnected: String(localized: "Les miniatures et le tri restent consultables. Branchez le disque pour exporter ou trier à nouveau : tout revient sans relancer LinkLens.")
        case .folderMissing: String(localized: "Le dossier a peut-être été déplacé, renommé ou supprimé. Les miniatures et le tri restent consultables.")
        }
    }

    /// Tooltip of a disabled action, nil when the action is possible.
    func help(for action: OriginalsAction) -> String? {
        guard let message else { return nil }
        let reason = switch action {
        case .export: String(localized: "L'export lit les fichiers originaux.")
        case .cull: String(localized: "Le tri lit les fichiers originaux.")
        case .trash: String(localized: "La mise à la corbeille déplace les fichiers originaux.")
        case .reveal: String(localized: "Le dossier n'est pas accessible.")
        }
        return "\(message). \(reason)"
    }

    /// The decision, from facts gathered elsewhere (kept pure so it can be tested without a disk).
    ///
    /// - `folderReachable`: the bookmark resolved, its permission was granted and the folder exists.
    /// - `remembered`: the volume as saved while the folder was reachable (nil for galleries indexed
    ///   before F9 whose disk was never seen since).
    static func evaluate(
        folderPath: String,
        folderReachable: Bool,
        remembered: VolumeIdentity?,
        mountedVolumes: [MountedVolume]
    ) -> GalleryAvailability {
        if folderReachable { return .available }
        // External disks are mounted under /Volumes. A folder elsewhere is on the Mac's own disk,
        // which is always there: the folder itself is missing.
        guard let mountPath = externalMountPath(of: folderPath) else { return .folderMissing }
        let isMounted = if let uuid = remembered?.uuid {
            // The same disk can come back at another path ("Photos 2TB 1" when the name is taken).
            mountedVolumes.contains { $0.uuid == uuid }
        } else {
            mountedVolumes.contains { $0.path == mountPath }
        }
        if isMounted { return .folderMissing }
        let name = remembered?.name ?? (mountPath as NSString).lastPathComponent
        return .diskDisconnected(volumeName: name)
    }

    /// "/Volumes/Photos 2TB" for "/Volumes/Photos 2TB/2026/Mariage", nil outside /Volumes.
    static func externalMountPath(of folderPath: String) -> String? {
        let components = (folderPath as NSString).pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        return "/Volumes/\(components[2])"
    }
}

/// The actions that need the original files (see `GalleryAvailability.help(for:)`).
enum OriginalsAction {
    case export, cull, trash, reveal
}

/// Result of checking one gallery, with what should be saved about it.
struct AvailabilityCheck: Sendable, Equatable {
    var galleryId: UUID
    var availability: GalleryAvailability
    /// The volume read now that the folder is reachable: saved so its name is known once unplugged.
    var volume: VolumeIdentity?
    /// A fresh bookmark and the new path when the folder was moved or renamed (stale bookmark).
    var refreshedBookmark: Data?
    var refreshedFolderPath: String?
}

/// Reads the facts about a gallery folder from the disk: bookmark, permission, folder, volumes.
/// Only reads; slow disks are checked off the main thread (`@concurrent`).
enum GalleryAvailabilityChecker {
    @concurrent
    static func check(_ galleries: [GalleryLocation]) async -> [AvailabilityCheck] {
        let mounted = MountedVolume.current()
        return galleries.map { check($0, mountedVolumes: mounted) }
    }

    static func check(_ gallery: GalleryLocation, mountedVolumes: [MountedVolume]) -> AvailabilityCheck {
        let remembered = gallery.volumeName.map { VolumeIdentity(name: $0, uuid: gallery.volumeUUID) }
        var result = AvailabilityCheck(galleryId: gallery.id, availability: .folderMissing)

        if let resolved = try? FolderBookmark.resolveWithoutMounting(gallery.folderBookmark),
           resolved.url.startAccessingSecurityScopedResource() {
            let folder = resolved.url
            defer { folder.stopAccessingSecurityScopedResource() }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            // A bookmark follows its folder everywhere, even into the trash: there it counts as gone.
            if exists, !FolderBookmark.isInTrash(folder) {
                result.availability = .available
                if let volume = VolumeIdentity.of(folder), volume != remembered {
                    result.volume = volume
                }
                let path = FolderBookmark.canonicalPath(of: folder)
                if resolved.isStale || path != gallery.folderPath {
                    result.refreshedBookmark = try? FolderBookmark.create(for: folder)
                    result.refreshedFolderPath = path
                }
                return result
            }
        }
        result.availability = GalleryAvailability.evaluate(
            folderPath: gallery.folderPath, folderReachable: false,
            remembered: remembered, mountedVolumes: mountedVolumes
        )
        return result
    }
}
