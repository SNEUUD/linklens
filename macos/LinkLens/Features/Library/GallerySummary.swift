import Foundation

/// What a sidebar row says about a gallery: counts, the verdict bar and the cover. Pure logic,
/// computed from plain copies of the photos so it can be tested without SwiftData.
struct GallerySummary: Equatable {
    /// The few fields of a photo the summary needs.
    struct Item: Equatable {
        var id: UUID
        var isVideo = false
        /// The verdict shown everywhere: the user's choice, otherwise the AI's proposal.
        var verdict: CullingVerdict?
        var burstNumber: Int?
        var aestheticsScore: Double?
    }

    var photoCount = 0
    var videoCount = 0
    var burstCount = 0
    var counts = VerdictCounts()
    /// Photos with no verdict yet (not sorted, or a verdict from a newer version of the app).
    var unsortedCount = 0
    /// Photos to try as the cover, best first (see `coverCandidates(of:)`).
    var coverCandidates: [UUID] = []

    /// How many candidates are tried before giving up on a cover: enough to skip the photos whose
    /// thumbnail is not made yet, without reading the cache folder for every photo of the gallery.
    static let coverCandidateLimit = 24

    init(_ items: [Item]) {
        var bursts = Set<Int>()
        for item in items {
            if item.isVideo {
                videoCount += 1
                continue
            }
            photoCount += 1
            if let burstNumber = item.burstNumber { bursts.insert(burstNumber) }
            switch item.verdict {
            case .keep: counts.keep += 1
            case .review: counts.review += 1
            case .reject: counts.reject += 1
            case .unknown, nil: unsortedCount += 1
            }
        }
        burstCount = bursts.count
        coverCandidates = Self.coverCandidates(of: items)
    }

    /// The best photo first: the photos to keep, highest aesthetics score first, then every other
    /// photo in the gallery order (so an unsorted gallery shows its first photo). Videos come last.
    static func coverCandidates(of items: [Item]) -> [UUID] {
        let photos = items.filter { !$0.isVideo }
        let keepers = photos
            .enumerated()
            .filter { $0.element.verdict == .keep }
            // Higher score first; photos without a score after, in gallery order.
            .sorted { lhs, rhs in
                let left = lhs.element.aestheticsScore ?? -.infinity
                let right = rhs.element.aestheticsScore ?? -.infinity
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element.id)
        let keeperIds = Set(keepers)
        let others = photos.map(\.id).filter { !keeperIds.contains($0) }
        let videos = items.filter(\.isVideo).map(\.id)
        return Array((keepers + others + videos).prefix(coverCandidateLimit))
    }

    /// The cover: the first candidate whose thumbnail is in the cache, nil if none is.
    static func cover(among candidates: [UUID], cached: Set<UUID>) -> UUID? {
        candidates.first { cached.contains($0) }
    }

    /// True once at least one photo has a verdict: the bar is worth drawing.
    var isSorted: Bool { counts.keep + counts.review + counts.reject > 0 }

    /// The parts of the verdict bar, in order, without the empty ones.
    var verdictSegments: [VerdictSegment] {
        let parts: [VerdictSegment] = [
            VerdictSegment(verdict: .keep, count: counts.keep),
            VerdictSegment(verdict: .review, count: counts.review),
            VerdictSegment(verdict: .reject, count: counts.reject),
            VerdictSegment(verdict: nil, count: unsortedCount),
        ]
        return parts.filter { $0.count > 0 }
    }

    /// What VoiceOver reads for the bar: « 12 à garder, 14 à revoir, 26 à rejeter ».
    var verdictBarDescription: String {
        guard isSorted else { return String(localized: "Pas encore triée") }
        var parts = [
            String(localized: "\(counts.keep) à garder"),
            String(localized: "\(counts.review) à revoir"),
            String(localized: "\(counts.reject) à rejeter"),
        ]
        if unsortedCount > 0 {
            parts.append(String(localized: "\(unsortedCount) pas encore triées"))
        }
        return parts.joined(separator: ", ")
    }
}

/// One coloured part of the verdict bar; `verdict` is nil for the photos not sorted yet.
struct VerdictSegment: Equatable {
    var verdict: CullingVerdict?
    var count: Int
}

extension Photo {
    var summaryItem: GallerySummary.Item {
        GallerySummary.Item(id: id, isVideo: mediaKind == .video, verdict: verdict, burstNumber: burstNumber, aestheticsScore: aestheticsScore)
    }
}

/// « ~/Downloads/photos » for a folder in the user's home, the full path otherwise.
/// `home` is passed in: inside the sandbox, `NSHomeDirectory()` is the app's container, not the
/// user's real home folder.
func abbreviatedPath(_ path: String, home: String) -> String {
    let home = home.hasSuffix("/") ? String(home.dropLast()) : home
    guard !home.isEmpty else { return path }
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// The user's real home folder (`/Users/chris`), even inside the sandbox.
func realHomeDirectory() -> String {
    // `getpwuid` reads the user database; it is not redirected to the container like `NSHomeDirectory()`.
    guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
    return String(cString: directory)
}
