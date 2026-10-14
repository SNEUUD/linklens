import Foundation

/// One item shown in the grid, the table or the viewer: a single photo, a collapsed burst
/// (its best photo stands for the whole burst) or one photo of an expanded burst.
struct GalleryEntry: Identifiable, Equatable, Sendable {
    /// Photo shown by this entry. A collapsed burst is shown by its best photo.
    var photoId: UUID
    /// Position of that photo in the list given to `BurstStacks.entries`.
    var photoIndex: Int
    var burst: BurstPlacement?

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
}

/// F4: groups the photos of each burst into a stack showing its best photo.
/// Pure logic, kept apart from SwiftUI and SwiftData so it can be tested.
enum BurstStacks {
    /// What the grouping needs to know about a photo.
    struct Input: Equatable, Sendable {
        var id: UUID
        var burstNumber: Int?
        var isBestOfBurst = false
    }

    /// - Parameters:
    ///   - photos: photos in display order (chronological).
    ///   - expanded: numbers of the bursts the user opened; the others are collapsed.
    /// - Returns: entries in display order. A burst always appears as one block, at the place of its
    ///   first photo, even if another photo was sorted between its members (e.g. a missing date).
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
            guard let number = photo.burstNumber, let burst = members[number] else {
                entries.append(GalleryEntry(photoId: photo.id, photoIndex: index))
                continue
            }
            // The whole burst is added when its first member is reached; the other members are skipped.
            guard burst[0] == index else { continue }

            // The best photo chosen by F3; the first one if none is marked (e.g. a failed analysis).
            let cover = burst.first { photos[$0].isBestOfBurst } ?? burst[0]
            let isExpanded = expanded.contains(number)
            let shown = isExpanded ? burst : [cover]
            for member in shown {
                let placement = BurstPlacement(number: number, count: burst.count, isExpanded: isExpanded, isCover: member == cover)
                entries.append(GalleryEntry(photoId: photos[member].id, photoIndex: member, burst: placement))
            }
        }
        return entries
    }
}
