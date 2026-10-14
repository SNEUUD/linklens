import AppKit
import SwiftData
import SwiftUI

/// The photos of a gallery, as a simple table (thumbnails come later).
struct GalleryDetailView: View {
    let gallery: Gallery
    @Query private var photos: [Photo]
    @State private var revealError: String?

    init(gallery: Gallery) {
        self.gallery = gallery
        let galleryId = gallery.id
        // `@Query` is the live query of SwiftData (like a `useQuery` hook that re-renders on every save).
        // Its filter depends on the gallery, so it is built here rather than in the property declaration.
        _photos = Query(
            filter: #Predicate<Photo> { $0.gallery?.id == galleryId },
            sort: [SortDescriptor(\.captureDate), SortDescriptor(\.relativePath)]
        )
    }

    var body: some View {
        Table(photos) {
            TableColumn("Fichier", value: \.relativePath)
            TableColumn("Prise de vue") { photo in
                if let captureDate = photo.captureDate {
                    Text(captureDate, format: .dateTime.day().month().year().hour().minute().second())
                } else {
                    Text(verbatim: "—")
                }
            }
            TableColumn("Dimensions") { photo in
                Text(verbatim: photo.pixelWidth > 0 ? "\(photo.pixelWidth) × \(photo.pixelHeight)" : "—")
                    .monospacedDigit()
            }
            TableColumn("Taille") { photo in
                Text(photo.fileSize, format: .byteCount(style: .file))
                    .monospacedDigit()
            }
        }
        .navigationTitle(gallery.name)
        .navigationSubtitle(gallery.folderPath)
        .toolbar {
            Button("Afficher dans le Finder", systemImage: "folder", action: revealInFinder)
        }
        .alert(
            "Dossier inaccessible",
            isPresented: Binding(get: { revealError != nil }, set: { if !$0 { revealError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(revealError ?? "")
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
