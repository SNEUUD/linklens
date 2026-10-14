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
    /// Photos stored so far, updated batch by batch (cheaper to display than `photos.count`).
    var photoCount: Int
    /// `nil` while indexing runs, set once every photo is stored.
    var indexedAt: Date?
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
