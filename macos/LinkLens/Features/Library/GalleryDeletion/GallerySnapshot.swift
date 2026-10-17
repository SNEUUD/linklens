import Foundation

/// Every stored field of a gallery and of its photos, kept while « Annuler » is possible after the
/// gallery was deleted: the undo puts it back exactly as it was. Same ids (so the cached thumbnails
/// and the remembered filter still match), the user's choices, the AI's verdicts and reasons, the
/// bursts and their best photos. The cover follows by itself: it is chosen from these values.
struct GallerySnapshot: Sendable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var folderPath: String
    var folderBookmark: Data
    var writeBookmark: Data?
    var volumeName: String?
    var volumeUUID: String?
    var photoCount: Int
    var videoCount: Int
    var indexedAt: Date?
    var culledAt: Date?
    /// Reuses F5's photo snapshot: one place lists the fields of a photo.
    var photos: [PhotoSnapshot]
}

extension Gallery {
    var snapshot: GallerySnapshot {
        GallerySnapshot(
            id: id, name: name, createdAt: createdAt, folderPath: folderPath, folderBookmark: folderBookmark,
            writeBookmark: writeBookmark, volumeName: volumeName, volumeUUID: volumeUUID,
            photoCount: photoCount, videoCount: videoCount, indexedAt: indexedAt, culledAt: culledAt,
            photos: photos.map(\.snapshot)
        )
    }

    /// The gallery as it was, without its photos (`LibraryStore.restoreGallery` adds them).
    convenience init(snapshot: GallerySnapshot) {
        self.init(
            id: snapshot.id, name: snapshot.name, folderPath: snapshot.folderPath,
            folderBookmark: snapshot.folderBookmark, createdAt: snapshot.createdAt
        )
        writeBookmark = snapshot.writeBookmark
        volumeName = snapshot.volumeName
        volumeUUID = snapshot.volumeUUID
        photoCount = snapshot.photoCount
        videoCount = snapshot.videoCount
        indexedAt = snapshot.indexedAt
        culledAt = snapshot.culledAt
    }
}
