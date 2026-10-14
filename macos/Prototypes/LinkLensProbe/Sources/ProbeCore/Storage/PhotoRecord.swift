import Foundation
import SwiftData

// `@Model` turns a class into a persisted table (like a Prisma `model`, but declared in Swift).
// SwiftData models must be classes: the framework tracks changes on shared instances.

@Model
public final class Gallery {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Photo.gallery)
    public var photos: [Photo] = []

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

@Model
public final class Photo {
    // SQL indexes for the typical query: "best non-rejected photos of a gallery".
    #Index<Photo>([\.verdictRaw, \.aestheticScore], [\.captureDate])

    @Attribute(.unique) public var id: UUID
    public var gallery: Gallery?
    public var relativePath: String
    public var captureDate: Date?
    public var importedAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fileSize: Int64
    public var aestheticScore: Double?
    public var sharpness: Double
    public var faceCount: Int
    public var eyesClosed: Bool
    /// "keep" / "review" / "reject" stored as text: `#Predicate` on enums is unreliable in SwiftData.
    public var verdictRaw: String
    public var reason: String
    public var burstId: UUID?
    public var isBestOfBurst: Bool
    public var sha256: String
    /// Vision feature print (~3 KB).
    public var featurePrint: Data

    init(draft: PhotoDraft) {
        id = draft.id
        relativePath = draft.relativePath
        captureDate = draft.captureDate
        importedAt = draft.importedAt
        pixelWidth = draft.pixelWidth
        pixelHeight = draft.pixelHeight
        fileSize = draft.fileSize
        aestheticScore = draft.aestheticScore
        sharpness = draft.sharpness
        faceCount = draft.faceCount
        eyesClosed = draft.eyesClosed
        verdictRaw = draft.verdict.rawValue
        reason = draft.reason
        burstId = draft.burstId
        isBestOfBurst = draft.isBestOfBurst
        sha256 = draft.sha256
        featurePrint = draft.featurePrint
    }
}

/// Plain `Sendable` copy of a photo, used to cross from the generator to the `ModelActor`.
/// `@Model` objects are not Sendable: they must stay inside the actor that owns their context.
struct PhotoDraft: Sendable {
    var id: UUID
    var relativePath: String
    var captureDate: Date?
    var importedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var aestheticScore: Double?
    var sharpness: Double
    var faceCount: Int
    var eyesClosed: Bool
    var verdict: Verdict
    var reason: String
    var burstId: UUID?
    var isBestOfBurst: Bool
    var sha256: String
    var featurePrint: Data
}

/// Read-only result of a query, Sendable so it can leave the actor.
public struct PhotoSummary: Sendable {
    public var relativePath: String
    public var aestheticScore: Double?
    public var verdict: String
}
