import Foundation

/// One item shown in the grid, the table or the viewer: a single photo, a collapsed burst
/// (its best photo stands for the whole burst) or one photo of an expanded burst.
struct GalleryEntry: Identifiable, Equatable, Sendable {
    /// Photo shown by this entry. A collapsed burst is shown by its best photo.
    var photoId: UUID
    /// Position of that photo in the list given to `BurstStacks.entries`.
    var photoIndex: Int
    var burst: BurstPlacement?
    /// True under a verdict filter for a photo the user sorted out of it: it stays in place, dimmed,
    /// until the filter changes (see `VerdictFilter`), so nothing moves under the cursor.
    var isOutsideFilter = false

    var id: UUID { photoId }
}

/// Where an entry sits in its burst.
struct BurstPlacement: Equatable, Sendable {
    /// Burst number in the gallery (1, 2…), as stored by F3.
    var number: Int
    /// Photos in the burst.
    var count: Int
    var isExpanded: Bool
    /// True for the best photo of the burst (the one shown when collapsed).
    var isCover: Bool
    /// True when the burst's best photo was chosen by the user (B key), false when it is the AI's.
    /// The same for every photo of the burst.
    var isCoverChosenByUser = false
    /// True under a verdict filter: the photo is shown on its own, among the other matching photos,
    /// without the rest of its burst (no stack, nothing to open or close).
    var isShownAlone = false
}

extension BurstPlacement {
    /// The star goes on the burst's best photo, but not on the first photo of a burst nobody chose
    /// (e.g. a failed analysis), which only stands in for it.
    func showsStar(isBestOfBurst: Bool) -> Bool {
        isCover && (isCoverChosenByUser || isBestOfBurst)
    }

    /// Spoken by VoiceOver and shown next to the star.
    var starDescription: String {
        isCoverChosenByUser
            ? String(localized: "Meilleure de la rafale, votre choix")
            : String(localized: "Meilleure de la rafale")
    }

    /// Read by VoiceOver with the photo's name and verdict: « Rafale de 7 photos, repliée ».
    var accessibilityDescription: String {
        if isShownAlone { return String(localized: "Rafale de \(count) photos") }
        return isExpanded
            ? String(localized: "Rafale de \(count) photos, ouverte")
            : String(localized: "Rafale de \(count) photos, repliée")
    }
}

/// F4: groups the photos of each burst into a stack showing its best photo.
/// Pure logic, kept apart from SwiftUI and SwiftData so it can be tested.
enum BurstStacks {
    /// What the grouping needs to know about a photo.
    struct Input: Equatable, Sendable {
        var id: UUID
        var burstNumber: Int?
        var isBestOfBurst = false
        /// When the user chose this photo as the best of its burst, nil if they did not.
        var bestChosenAt: Date?
        /// The verdict shown (the user's choice, otherwise the AI's), for the verdict filters.
        var verdict: CullingVerdict?
        /// True when `verdict` is the user's choice (P, U, X), false when it is the AI's proposal.
        var isVerdictChosenByUser = false
    }

    /// - Parameters:
    ///   - photos: photos in display order (chronological).
    ///   - expanded: numbers of the bursts the user opened; the others are collapsed.
    /// - Returns: entries in display order. A burst always appears as one block, at the place of its
    ///   first photo, even if another photo was sorted between its members (e.g. a missing date).
    ///   A burst left with one photo (the others put in the trash) is shown as a single photo.
    static func entries(for photos: [Input], expanded: Set<Int>) -> [GalleryEntry] {
        // Indices of the members of each burst, in display order.
        // `[Int: [Int]]` is a dictionary, like a `Map<number, number[]>` in TypeScript.
        var members: [Int: [Int]] = [:]
        for (index, photo) in photos.enumerated() {
            if let number = photo.burstNumber {
                members[number, default: []].append(index)
            }
        }

        var entries: [GalleryEntry] = []
        entries.reserveCapacity(photos.count)
        for (index, photo) in photos.enumerated() {
            guard let number = photo.burstNumber, let burst = members[number], burst.count > 1 else {
                entries.append(GalleryEntry(photoId: photo.id, photoIndex: index))
                continue
            }
            // The whole burst is added when its first member is reached; the other members are skipped.
            guard burst[0] == index else { continue }

            let (cover, isChosenByUser) = Self.cover(of: burst, in: photos)
            let isExpanded = expanded.contains(number)
            let shown = isExpanded ? burst : [cover]
            for member in shown {
                let placement = BurstPlacement(
                    number: number, count: burst.count, isExpanded: isExpanded,
                    isCover: member == cover, isCoverChosenByUser: isChosenByUser
                )
                entries.append(GalleryEntry(photoId: photos[member].id, photoIndex: member, burst: placement))
            }
        }
        return entries
    }

    /// The best photo of a burst (`burst` holds positions in `photos`): the user's choice (B), else the AI's,
    /// else the first photo. Also used by the review of the « À revoir » photos.
    static func cover(of burst: [Int], in photos: [Input]) -> (index: Int, isChosenByUser: Bool) {
        if let chosen = userChosenCover(of: burst, in: photos) { return (chosen, true) }
        return (aiCover(of: burst, in: photos), false)
    }

    /// The photo the user chose most recently in this burst, nil if they chose none. Choices are tied to
    /// photos, not to burst numbers: after a new sorting they follow their photo into its new burst.
    /// When two bursts merge, the most recent choice wins; the older one stays stored, unused.
    private static func userChosenCover(of burst: [Int], in photos: [Input]) -> Int? {
        // `compactMap` drops the nils, like `.map(…).filter(x => x != null)` in TypeScript.
        let chosen = burst.compactMap { index in photos[index].bestChosenAt.map { (index, $0) } }
        // `max(by:)` keeps the first of equal elements, so equal dates give the earliest photo.
        return chosen.max { $0.1 < $1.1 }?.0
    }

    /// The best photo chosen by F3; the first one if none is marked (e.g. a failed analysis).
    private static func aiCover(of burst: [Int], in photos: [Input]) -> Int {
        burst.first { photos[$0].isBestOfBurst } ?? burst[0]
    }

    /// What `nextCover(among:)` compares.
    struct CoverCandidate: Equatable, Sendable {
        var id: UUID
        var verdict: CullingVerdict?
        var aesthetics: Double?
        var sharpness: Double?
    }

    /// The photo that becomes the best of its burst when the AI's best photo was put in the trash:
    /// a photo to keep before one to review before a rejected one, then the best aesthetics score,
    /// then the sharpest, then the first in the burst. Nil for an empty list.
    static func nextCover(among candidates: [CoverCandidate]) -> UUID? {
        func rank(_ verdict: CullingVerdict?) -> Int {
            switch verdict {
            case .keep: 0
            case .review: 1
            case .reject, .unknown, nil: 2
            }
        }
        // `min(by:)` keeps the first of equal elements: on a tie, the earliest photo wins.
        return candidates.min { first, second in
            if rank(first.verdict) != rank(second.verdict) { return rank(first.verdict) < rank(second.verdict) }
            let (a, b) = (first.aesthetics ?? -.infinity, second.aesthetics ?? -.infinity)
            if a != b { return a > b }
            return (first.sharpness ?? -.infinity) > (second.sharpness ?? -.infinity)
        }?.id
    }
}

extension BurstStacks {
    /// What a verdict filter shows. « Toutes »: the bursts stacked as usual. Any other filter: every
    /// matching photo one by one, bursts unfolded, so each « À revoir » photo of a burst can be checked.
    ///
    /// - Parameter retained: photos to keep showing even if they no longer match (sorted by the user
    ///   while this filter is on). They come back marked `isOutsideFilter`.
    static func entries(
        for photos: [Input],
        expanded: Set<Int>,
        filter: VerdictFilter,
        retaining retained: Set<UUID> = []
    ) -> [GalleryEntry] {
        guard filter != .all else { return entries(for: photos, expanded: expanded) }
        // Every burst open: each photo gets its own entry, still placed in its burst's block.
        let everyBurst = Set(photos.compactMap(\.burstNumber))
        return entries(for: photos, expanded: everyBurst).compactMap { entry in
            let matches = filter.matches(photos[entry.photoIndex].verdict)
            guard matches || retained.contains(entry.photoId) else { return nil }
            var shown = entry
            shown.burst?.isShownAlone = true
            shown.isOutsideFilter = !matches
            return shown
        }
    }
}
