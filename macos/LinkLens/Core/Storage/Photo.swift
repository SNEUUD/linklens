import Foundation
import SwiftData

/// A photo file of a gallery. Only its location and metadata are stored: the file never moves.
/// The analysis fields (score, verdict, reason…) arrive with F3, as optional properties.
@Model
final class Photo {
    #Index<Photo>([\.captureDate])

    @Attribute(.unique) var id: UUID
    var gallery: Gallery?
    /// Path relative to the gallery folder, e.g. "DSC04297.ARW" or "Jour 2/IMG_0001.HEIC".
    var relativePath: String
    var fileSize: Int64
    var captureDate: Date?
    /// Dimensions as displayed (swapped for portrait photos), 0 when the file could not be read.
    var pixelWidth: Int
    var pixelHeight: Int
    var importedAt: Date

    init(draft: PhotoDraft) {
        id = draft.id
        relativePath = draft.relativePath
        fileSize = draft.fileSize
        captureDate = draft.captureDate
        pixelWidth = draft.pixelWidth
        pixelHeight = draft.pixelHeight
        importedAt = draft.importedAt
    }
}

/// Plain `Sendable` copy of a photo, used to cross from the indexer to the `ModelActor`.
/// `@Model` objects are not Sendable: they must stay inside the actor that owns their context.
struct PhotoDraft: Sendable, Equatable {
    var id = UUID()
    var relativePath: String
    var fileSize: Int64
    var captureDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var importedAt: Date

    init(file: PhotoFile, metadata: PhotoMetadata, importedAt: Date) {
        relativePath = file.relativePath
        fileSize = file.fileSize
        captureDate = metadata.captureDate
        pixelWidth = metadata.pixelWidth
        pixelHeight = metadata.pixelHeight
        self.importedAt = importedAt
    }
}
