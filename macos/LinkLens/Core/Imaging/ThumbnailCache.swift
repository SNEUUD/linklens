import CoreGraphics
import Foundation

/// On-disk thumbnail cache, in the app's sandbox container: one JPEG per photo, named after the photo's id.
///
/// The id (not the path) is the key, so a thumbnail survives a renamed folder or an unplugged disk:
/// F9 will show the gallery from this cache when the files are out of reach. It lives in
/// Application Support rather than Caches, which macOS may empty on its own.
///
/// A `struct` with only constant properties is `Sendable` (safe to share between threads), like a
/// frozen object in TypeScript. No `actor` is needed: each photo has its own file, written atomically.
struct ThumbnailCache: Sendable {
    let directory: URL

    /// The app's cache: `~/Library/Containers/<app>/Data/Library/Application Support/Thumbnails`.
    static let standard = ThumbnailCache(directory: .applicationSupportDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory))

    func fileURL(for photoId: UUID) -> URL {
        directory.appending(path: "\(photoId.uuidString).jpg")
    }

    func contains(_ photoId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: photoId).path)
    }

    /// The cached thumbnail, already decoded, or nil if it was never made.
    func image(for photoId: UUID) -> CGImage? {
        ThumbnailGenerator.decodeJPEG(at: fileURL(for: photoId))
    }

    func store(_ image: CGImage, for photoId: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `.atomic` writes a temporary file then renames it: a reader never sees half a JPEG.
        try ThumbnailGenerator.jpegData(from: image).write(to: fileURL(for: photoId), options: .atomic)
    }

    /// Removes the thumbnails of photos that left the catalogue for good (a deleted gallery, once
    /// « Annuler » is no longer possible). Missing files are skipped.
    func remove(_ photoIds: [UUID]) {
        for photoId in photoIds {
            try? FileManager.default.removeItem(at: fileURL(for: photoId))
        }
    }

    /// Ids among `photoIds` that have no thumbnail yet, in the same order.
    func missing(among photoIds: [UUID]) -> [UUID] {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return photoIds.filter { !existing.contains("\($0.uuidString).jpg") }
    }
}
