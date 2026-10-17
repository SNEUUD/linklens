import AppKit

/// Opens a gallery folder read-write: to put duplicates in the trash (F5), or the whole folder with
/// the gallery. The sandbox only lets the app change a folder the user picked, so the first time the
/// folder is shown in a panel and the user clicks « Autoriser »; the permission is then saved
/// (`Gallery.writeBookmark`) and not asked again.
@MainActor
enum GalleryWriteAccess {
    enum Outcome {
        /// `isAccessing`: `stopAccessingSecurityScopedResource()` must be called when done.
        case opened(URL, isAccessing: Bool)
        /// The user closed the panel.
        case refused
        /// The user picked another folder than the gallery's.
        case wrongFolder
    }

    /// The saved read-write bookmark when there is one, otherwise the user is asked through `askUser`.
    static func open(
        _ gallery: GalleryLocation,
        store: LibraryStore,
        askUser: @MainActor (GalleryLocation) -> URL?
    ) async -> Outcome {
        if let bookmark = gallery.writeBookmark,
           let folder = try? FolderBookmark.resolve(bookmark),
           folder.startAccessingSecurityScopedResource() {
            return .opened(folder, isAccessing: true)
        }
        guard let chosen = askUser(gallery) else { return .refused }
        guard FolderBookmark.canonicalPath(of: chosen) == gallery.folderPath else { return .wrongFolder }
        if let bookmark = try? FolderBookmark.createReadWrite(for: chosen) {
            try? await store.setWriteBookmark(bookmark, galleryId: gallery.id)
        }
        // A folder picked in the panel is open until the app quits; `startAccessing…` may return false.
        return .opened(chosen, isAccessing: chosen.startAccessingSecurityScopedResource())
    }

    /// The panel: the gallery's folder is shown, the user clicks « Autoriser ». `message` says why.
    static func askUser(for gallery: GalleryLocation, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(filePath: gallery.folderPath, directoryHint: .isDirectory)
        panel.prompt = String(localized: "Autoriser")
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
