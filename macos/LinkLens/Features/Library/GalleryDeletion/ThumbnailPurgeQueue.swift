import Foundation

/// The thumbnails of deleted galleries, waiting to leave the cache. They stay as long as « Annuler »
/// is possible (the restored gallery finds them again, same photo ids), and go once it is not: at the
/// end of the undo period, when the app quits, or at the next launch after a crash.
///
/// Written to a small JSON file rather than kept in memory only, so a forced quit never leaves them
/// in the cache forever. Used from the main actor only (`GalleryDeletionController`).
struct ThumbnailPurgeQueue: Sendable {
    let fileURL: URL

    /// Next to the thumbnail folder, in the app's container.
    static let standard = ThumbnailPurgeQueue(
        fileURL: ThumbnailCache.standard.directory.deletingLastPathComponent().appending(path: "PendingThumbnailRemovals.json")
    )

    /// Gallery id → its photo ids.
    func pending() -> [UUID: [UUID]] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        var result: [UUID: [UUID]] = [:]
        for (galleryId, photoIds) in stored {
            guard let galleryId = UUID(uuidString: galleryId) else { continue }
            result[galleryId] = photoIds.compactMap(UUID.init(uuidString:))
        }
        return result
    }

    func add(galleryId: UUID, photoIds: [UUID]) {
        var all = pending()
        all[galleryId] = photoIds
        save(all)
    }

    func remove(galleryId: UUID) {
        var all = pending()
        guard all.removeValue(forKey: galleryId) != nil else { return }
        save(all)
    }

    private func save(_ all: [UUID: [UUID]]) {
        if all.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let stored = Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString, $0.value.map(\.uuidString)) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
