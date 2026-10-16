import CoreGraphics
import Foundation
import SwiftData

/// A photo (or, since F1, a video) file of a gallery. Only its location, metadata and analysis results
/// are stored: the file never moves.
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
    /// Raw value of `MediaKind`. Nil for the photos indexed before F1 (they are all photos).
    var mediaKindRaw: String?

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

    // Manual sorting. Kept apart from `cullingVerdictRaw`: a new AI sorting never overwrites it.
    /// Raw value of the `CullingVerdict` chosen by the user, nil when they kept the AI's proposal.
    var userVerdictRaw: String?
    /// When the user chose this photo as the best of its burst (F4), nil if they did not. Kept apart from
    /// `isBestOfBurst` (the AI's choice) and tied to the photo, not to `burstNumber`, which changes on every
    /// sorting. A date rather than a Boolean: when two bursts merge, the most recent choice wins.
    var bestOfBurstChosenAt: Date?

    // F5 duplicates.
    /// SHA-256 of the file (hexadecimal): known after a card import (F1), otherwise computed on demand
    /// by the duplicate search, only for files whose size matches another file's.
    var sha256: String?

    // Inspector (interface batch 3). All optional: SwiftData adds the columns to older catalogues by
    // itself (a "lightweight migration"), and nil means "not read yet". Stored rather than read on
    // demand, so the inspector still shows everything while the disk is unplugged (F9).
    /// EXIF, read at indexing time (or by `DetailsBackfiller` for photos indexed earlier).
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    /// Seconds (0.00625 = 1/160 s).
    var exposureTime: Double?
    var fNumber: Double?
    var iso: Int?
    /// Millimetres.
    var focalLength: Double?
    /// Main subject found by Vision during the analysis, normalized (0…1) with a top-left origin.
    /// Four numbers rather than a `CGRect`: plain columns that every SwiftData version stores the same way.
    var subjectX: Double?
    var subjectY: Double?
    var subjectWidth: Double?
    var subjectHeight: Double?
    /// Share of burnt highlights and blocked shadows (0…1), measured by the analysis.
    var highlightClipping: Double?
    var shadowClipping: Double?
    /// Length of a video, in seconds.
    var videoDuration: Double?
    /// When the analysis details above (subject, exposure) were last read from the file, even if the file
    /// could not be read then. Nil for a photo analysed before batch 3: `DetailsBackfiller` fills it in.
    var detailsReadAt: Date?

    init(draft: PhotoDraft) {
        id = draft.id
        relativePath = draft.relativePath
        fileSize = draft.fileSize
        captureDate = draft.captureDate
        pixelWidth = draft.pixelWidth
        pixelHeight = draft.pixelHeight
        importedAt = draft.importedAt
        mediaKindRaw = draft.mediaKind.rawValue
        capture = draft.capture
        videoDuration = draft.duration
        // A video has no analysis: what the inspector shows of it was just read.
        if draft.mediaKind == .video { detailsReadAt = draft.importedAt }
    }
}

// A computed property (`var x: T { … }`) has no storage: it is recomputed on each read,
// like a getter in a TypeScript class. SwiftData does not persist it.
extension Photo {
    var mediaKind: MediaKind { MediaKind(stored: mediaKindRaw) }

    /// Nil while the photo has not been analysed.
    var cullingVerdict: CullingVerdict? {
        cullingVerdictRaw.map { CullingVerdict(rawValue: $0) ?? .unknown }
    }

    /// The user's choice, nil when they did not choose (the AI's proposal then applies).
    var userVerdict: CullingVerdict? {
        userVerdictRaw.map { CullingVerdict(rawValue: $0) ?? .unknown }
    }

    /// The verdict shown and used everywhere (counters, export, duplicates): the user's choice,
    /// otherwise the AI's proposal. `cullingVerdict` alone is only the AI's proposal.
    var verdict: CullingVerdict? {
        userVerdict ?? cullingVerdict
    }

    /// Camera, lens and settings, as read from the EXIF.
    var capture: CaptureInfo {
        get {
            CaptureInfo(
                cameraMake: cameraMake, cameraModel: cameraModel, lensModel: lensModel,
                exposureTime: exposureTime, fNumber: fNumber, iso: iso, focalLength: focalLength
            )
        }
        set {
            cameraMake = newValue.cameraMake
            cameraModel = newValue.cameraModel
            lensModel = newValue.lensModel
            exposureTime = newValue.exposureTime
            fNumber = newValue.fNumber
            iso = newValue.iso
            focalLength = newValue.focalLength
        }
    }

    /// Nil when unknown: not analysed yet, no subject found, or analysed before batch 3.
    var subjectBox: CGRect? {
        get {
            guard let subjectX, let subjectY, let subjectWidth, let subjectHeight else { return nil }
            return CGRect(x: subjectX, y: subjectY, width: subjectWidth, height: subjectHeight)
        }
        set {
            subjectX = newValue.map { Double($0.minX) }
            subjectY = newValue.map { Double($0.minY) }
            subjectWidth = newValue.map { Double($0.width) }
            subjectHeight = newValue.map { Double($0.height) }
        }
    }

    var cullingReasons: [CullingReason] {
        guard let cullingReasonsData else { return [] }
        return (try? JSONDecoder().decode([CullingReason].self, from: cullingReasonsData)) ?? []
    }

    /// Stores the AI's result. `userVerdictRaw` and `bestOfBurstChosenAt` are left alone: manual choices
    /// survive a new sorting.
    func apply(_ result: CullingResult, analyzedAt: Date) throws {
        cullingVerdictRaw = result.verdict.rawValue
        cullingReasonsData = try JSONEncoder().encode(result.reasons)
        self.analyzedAt = analyzedAt
        sharpness = result.sharpness
        aestheticsScore = result.aesthetics
        burstNumber = result.burstNumber
        isBestOfBurst = result.isBestOfBurst
        // A photo that could not be read keeps what was known of it.
        if let measured = result.measured {
            apply(PhotoDetails(photoId: id, capture: result.capture, measured: measured, readAt: analyzedAt))
        }
    }

    /// Stores what the inspector shows. Only these fields: never a verdict nor a choice of the user.
    func apply(_ details: PhotoDetails) {
        if let capture = details.capture { self.capture = capture }
        if let measured = details.measured {
            subjectBox = measured.subjectBox
            highlightClipping = measured.highlightClipping
            shadowClipping = measured.shadowClipping
        }
        if let duration = details.videoDuration { videoDuration = duration }
        detailsReadAt = details.readAt
    }
}

/// What the analysis (or `DetailsBackfiller`) learnt about a photo for the inspector, apart from its verdict.
/// A nil part was not read (unreadable file) and leaves the stored values as they are.
struct PhotoDetails: Sendable, Equatable {
    struct Measured: Sendable, Equatable {
        var subjectBox: CGRect?
        var highlightClipping: Double
        var shadowClipping: Double
    }

    var photoId: UUID
    var capture: CaptureInfo? = nil
    var measured: Measured? = nil
    var videoDuration: Double? = nil
    var readAt: Date
}

/// Every stored field of a photo, kept while its file is in the trash (F5) so "Annuler" can put the
/// photo back exactly as it was: same id (so the cached thumbnail still matches), verdict and reasons.
struct PhotoSnapshot: Sendable, Equatable {
    var id: UUID
    var relativePath: String
    var fileSize: Int64
    var captureDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var importedAt: Date
    var mediaKindRaw: String?
    var cullingVerdictRaw: String?
    var cullingReasonsData: Data?
    var analyzedAt: Date?
    var sharpness: Double?
    var aestheticsScore: Double?
    var burstNumber: Int?
    var isBestOfBurst: Bool
    var sha256: String?
    var userVerdictRaw: String? = nil
    var bestOfBurstChosenAt: Date? = nil
    var capture = CaptureInfo()
    var subjectBox: CGRect? = nil
    var highlightClipping: Double? = nil
    var shadowClipping: Double? = nil
    var videoDuration: Double? = nil
    var detailsReadAt: Date? = nil
}

extension Photo {
    var snapshot: PhotoSnapshot {
        PhotoSnapshot(
            id: id, relativePath: relativePath, fileSize: fileSize, captureDate: captureDate,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, importedAt: importedAt, mediaKindRaw: mediaKindRaw,
            cullingVerdictRaw: cullingVerdictRaw, cullingReasonsData: cullingReasonsData, analyzedAt: analyzedAt,
            sharpness: sharpness, aestheticsScore: aestheticsScore, burstNumber: burstNumber,
            isBestOfBurst: isBestOfBurst, sha256: sha256, userVerdictRaw: userVerdictRaw,
            bestOfBurstChosenAt: bestOfBurstChosenAt, capture: capture, subjectBox: subjectBox,
            highlightClipping: highlightClipping, shadowClipping: shadowClipping,
            videoDuration: videoDuration, detailsReadAt: detailsReadAt
        )
    }

    // A `convenience init` must call another initializer of the class first (here `init(draft:)`),
    // then may set the remaining properties. It is the only kind of init a class extension may add.
    convenience init(snapshot: PhotoSnapshot) {
        var draft = PhotoDraft(
            file: PhotoFile(url: URL(filePath: snapshot.relativePath), relativePath: snapshot.relativePath, fileSize: snapshot.fileSize),
            metadata: PhotoMetadata(captureDate: snapshot.captureDate, pixelWidth: snapshot.pixelWidth, pixelHeight: snapshot.pixelHeight),
            importedAt: snapshot.importedAt
        )
        draft.id = snapshot.id
        self.init(draft: draft)
        mediaKindRaw = snapshot.mediaKindRaw
        cullingVerdictRaw = snapshot.cullingVerdictRaw
        cullingReasonsData = snapshot.cullingReasonsData
        analyzedAt = snapshot.analyzedAt
        sharpness = snapshot.sharpness
        aestheticsScore = snapshot.aestheticsScore
        burstNumber = snapshot.burstNumber
        isBestOfBurst = snapshot.isBestOfBurst
        sha256 = snapshot.sha256
        userVerdictRaw = snapshot.userVerdictRaw
        bestOfBurstChosenAt = snapshot.bestOfBurstChosenAt
        capture = snapshot.capture
        subjectBox = snapshot.subjectBox
        highlightClipping = snapshot.highlightClipping
        shadowClipping = snapshot.shadowClipping
        videoDuration = snapshot.videoDuration
        detailsReadAt = snapshot.detailsReadAt
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
    var mediaKind: MediaKind
    var capture: CaptureInfo
    var duration: Double?

    init(file: PhotoFile, metadata: PhotoMetadata, importedAt: Date) {
        relativePath = file.relativePath
        mediaKind = file.kind
        fileSize = file.fileSize
        captureDate = metadata.captureDate
        pixelWidth = metadata.pixelWidth
        pixelHeight = metadata.pixelHeight
        capture = metadata.capture
        duration = metadata.duration
        self.importedAt = importedAt
    }
}
