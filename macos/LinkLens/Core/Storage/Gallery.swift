import Foundation
import SwiftData

// `@Model` turns a class into a persisted table (like a Prisma `model`, but declared in Swift).
// SwiftData models must be classes: the framework tracks changes on shared instances.

/// A photo session shown in the library. With F2 it points to an existing folder, indexed in place.
@Model
final class Gallery {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// Folder path at indexing time: shown to the user and used to detect a folder indexed twice.
    var folderPath: String
    /// Security-scoped bookmark: lets the sandboxed app reopen the folder after a restart.
    var folderBookmark: Data
    /// Read-write bookmark of the same folder, only needed to put duplicates in the trash (F5).
    /// Set by a card import (F1), or once the user has allowed it; nil for a folder only indexed (F2).
    var writeBookmark: Data?
    /// Name and id of the disk the folder is on, saved while it is mounted (F9): once the disk is
    /// unplugged, the app can still say « Disque « Photos 2TB » non connecté ». Nil until first seen.
    var volumeName: String?
    var volumeUUID: String?
    /// Photos and videos stored so far, updated batch by batch (cheaper to display than `photos.count`).
    var photoCount: Int
    /// How many of `photoCount` are videos (F1). A default value lets SwiftData migrate older catalogues.
    var videoCount = 0
    /// `nil` while indexing runs, set once every photo is stored.
    var indexedAt: Date?
    /// Last time the AI sorting (F3) finished for the whole gallery; nil if never sorted.
    var culledAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \Photo.gallery)
    var photos: [Photo] = []

    init(id: UUID = UUID(), name: String, folderPath: String, folderBookmark: Data, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.photoCount = 0
        self.indexedAt = nil
    }
}
