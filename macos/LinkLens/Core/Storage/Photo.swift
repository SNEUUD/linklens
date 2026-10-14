import Foundation
import SwiftData

/// A photo file of a gallery. Only its location, metadata and analysis results are stored: the file never moves.
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

    // F3 culling. Optional or with a default value, so SwiftData migrates older catalogues by itself.
    /// Raw value of `CullingVerdict` (a plain string can be filtered and sorted in a `#Predicate`).
    var cullingVerdictRaw: String?
    /// `[CullingReason]` encoded as JSON, most severe first.
    var cullingReasonsData: Data?
    var analyzedAt: Date?
    /// Subject sharpness relative to its contrast (see `SharpnessMeasurement`).
    var sharpness: Double?
    /// Vision aesthetics score (−1…1).
    var aestheticsScore: Double?
    /// Burst number within the gallery (1, 2…), nil if the photo is not part of a burst. Used by F4.
    var burstNumber: Int?
    var isBestOfBurst = false

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

// A computed property (`var x: T { … }`) has no storage: it is recomputed on each read,
// like a getter in a TypeScript class. SwiftData does not persist it.
extension Photo {
    /// Nil while the photo has not been analysed.
    var cullingVerdict: CullingVerdict? {
        cullingVerdictRaw.map { CullingVerdict(rawValue: $0) ?? .unknown }
    }

    var cullingReasons: [CullingReason] {
        guard let cullingReasonsData else { return [] }
        return (try? JSONDecoder().decode([CullingReason].self, from: cullingReasonsData)) ?? []
    }

    func apply(_ result: CullingResult, analyzedAt: Date) throws {
        cullingVerdictRaw = result.verdict.rawValue
        cullingReasonsData = try JSONEncoder().encode(result.reasons)
        self.analyzedAt = analyzedAt
        sharpness = result.sharpness
        aestheticsScore = result.aesthetics
        burstNumber = result.burstNumber
        isBestOfBurst = result.isBestOfBurst
    }
}

/// Plain `Sendable` copy of the fields the analysis needs, read by `LibraryStore`.
struct PhotoReference: Sendable, Equatable {
    var id: UUID
    var relativePath: String
    var captureDate: Date?
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
