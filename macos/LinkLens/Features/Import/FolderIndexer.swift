import Foundation

struct IndexingProgress: Sendable, Equatable {
    var galleryId: UUID
    var completed: Int
    var total: Int

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

enum IndexingResult: Sendable, Equatable {
    case indexed(galleryId: UUID, photoCount: Int)
    /// The folder was already a gallery: nothing is created, the existing one is returned.
    case alreadyIndexed(galleryId: UUID)
}

/// F2: indexes an existing folder in place. Files are only read, never copied, moved or renamed.
///
/// Steps: bookmark → scan → metadata → batches written by `LibraryStore` → gallery marked as indexed.
/// On error or cancellation the partial gallery is removed from the catalogue (the files stay untouched).
struct FolderIndexer: Sendable {
    let store: LibraryStore
    var batchSize = 200

    /// `@concurrent` runs this function on a background thread even when called from the interface,
    /// so scanning and reading metadata never freeze the window.
    @concurrent
    func indexFolder(
        at selectedFolder: URL,
        onProgress: @MainActor @Sendable (IndexingProgress) -> Void = { _ in }
    ) async throws -> IndexingResult {
        // The bookmark is created and resolved right away: if it does not work, better know it now.
        let bookmark = try FolderBookmark.create(for: selectedFolder)
        let folder = try FolderBookmark.resolve(bookmark)
        guard folder.startAccessingSecurityScopedResource() else {
            throw LibraryError.accessDenied(folder.lastPathComponent)
        }
        // `defer` runs when the function exits, whatever the path (like `finally` in TypeScript).
        defer { folder.stopAccessingSecurityScopedResource() }

        let folderPath = FolderBookmark.canonicalPath(of: folder)
        if let existing = try await store.galleryId(forFolderPath: folderPath) {
            return .alreadyIndexed(galleryId: existing)
        }

        let files = try PhotoScanner.scan(folder: folder)
        guard !files.isEmpty else {
            throw LibraryError.noPhotos(folder.lastPathComponent)
        }

        let galleryId = try await store.createGallery(
            name: folder.lastPathComponent,
            folderPath: folderPath,
            folderBookmark: bookmark
        )
        do {
            await onProgress(IndexingProgress(galleryId: galleryId, completed: 0, total: files.count))
            var completed = 0
            for start in stride(from: 0, to: files.count, by: batchSize) {
                try Task.checkCancellation()
                let importedAt = Date()
                let drafts = files[start..<min(start + batchSize, files.count)].map { file in
                    PhotoDraft(file: file, metadata: PhotoMetadataReader.read(url: file.url), importedAt: importedAt)
                }
                try await store.insert(drafts, galleryId: galleryId)
                completed += drafts.count
                await onProgress(IndexingProgress(galleryId: galleryId, completed: completed, total: files.count))
            }
            try await store.finishIndexing(galleryId: galleryId)
            return .indexed(galleryId: galleryId, photoCount: completed)
        } catch {
            try? await store.deleteGallery(id: galleryId)
            throw error
        }
    }
}
