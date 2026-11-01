import CoreGraphics
import Foundation

/// Everything the gallery view derives from its photos, read in a single pass.
///
/// Reading a property of a SwiftData `Photo` costs about a microsecond and a half: one pass over the
/// 4 120 photos of a gallery takes 6 to 38 ms. The view used to make a dozen passes on each update
/// (a click, a selection), and looked photos up one by one after a deletion (several seconds). Here
/// every value is computed once, and photos are found by id in a dictionary.
@MainActor
struct GalleryPhotos {
    /// The photos of the query, in display order.
    let photos: [Photo]
    let byId: [UUID: Photo]
    /// What the browser and the review need about each photo, in the same order as `photos`.
    let burstInputs: [BurstStacks.Input]
    let counts: VerdictFilterCounts
    /// Photos, videos left out (« 52 photos » under the gallery name).
    let photoCount: Int
    /// The photos waiting for their disk to go to the trash, in display order.
    let pending: [Photo]
    /// « Rejeter » photos not waiting for the trash yet (what « en attente de corbeille… » would mark).
    let rejectedNotPendingCount: Int
    /// Width / height of the thumbnails, the dominant shape of the gallery (`ThumbnailShape`).
    let cellAspectRatio: CGFloat

    init(_ photos: [Photo]) {
        self.photos = photos
        var byId: [UUID: Photo] = [:]
        byId.reserveCapacity(photos.count)
        var burstInputs: [BurstStacks.Input] = []
        burstInputs.reserveCapacity(photos.count)
        var sizes: [(width: Int, height: Int)] = []
        sizes.reserveCapacity(photos.count)
        var photoCount = 0
        var pending: [Photo] = []
        var rejectedNotPendingCount = 0
        for photo in photos {
            let input = photo.burstInput
            // A duplicate id would be a catalogue error: the first photo wins, as before.
            if byId[input.id] == nil { byId[input.id] = photo }
            burstInputs.append(input)
            sizes.append((photo.pixelWidth, photo.pixelHeight))
            if photo.mediaKind != .video { photoCount += 1 }
            if photo.isPendingTrash {
                pending.append(photo)
            } else if input.verdict == .reject {
                rejectedNotPendingCount += 1
            }
        }
        self.byId = byId
        self.burstInputs = burstInputs
        counts = VerdictFilterCounts(burstInputs.map(\.verdict))
        self.photoCount = photoCount
        self.pending = pending
        self.rejectedNotPendingCount = rejectedNotPendingCount
        cellAspectRatio = ThumbnailShape.cellAspectRatio(sizes: sizes)
    }

    func photo(id: UUID?) -> Photo? {
        id.flatMap { byId[$0] }
    }

    /// Every photo of a burst, in display order.
    func burstMembers(of burstNumber: Int) -> [Photo] {
        zip(photos, burstInputs).compactMap { photo, input in input.burstNumber == burstNumber ? photo : nil }
    }
}

/// Keeps `GalleryPhotos` for one update of the gallery view, so the toolbar, the filters, the menus and
/// the inspector share one pass instead of making their own.
///
/// A plain class (not `@Observable`) kept in a `@State`: changing it never asks SwiftUI to redraw, like a
/// `useRef` in React. `body` calls `reset` first, so every update starts from the current photos.
@MainActor
final class GalleryPhotosCache {
    private var photos: [Photo] = []
    private var cached: GalleryPhotos?

    func reset(_ photos: [Photo]) {
        self.photos = photos
        cached = nil
    }

    var value: GalleryPhotos {
        if let cached { return cached }
        let value = GalleryPhotos(photos)
        cached = value
        return value
    }
}
