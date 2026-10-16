import CoreGraphics

/// The shape of the grid cells: the dominant orientation of the gallery, so portrait sessions get
/// portrait cells instead of grey bands on both sides.
///
/// `Photo.pixelWidth` / `pixelHeight` are stored as displayed (EXIF orientation already applied by
/// `PhotoMetadataReader`): the A6000 RAW files say 6000 × 4000 with orientation 8, stored 4000 × 6000.
enum ThumbnailShape {
    /// When no photo has known dimensions yet.
    static let defaultAspectRatio: CGFloat = 3 / 2

    /// Width / height of every cell of the gallery.
    ///
    /// The orientation most photos have wins (portrait, landscape or square); a tie between portraits
    /// and landscapes gives square cells, fair to both. Within the winning orientation, the most
    /// common ratio is used (2:3 for a camera, 3:4 for a phone). Unknown sizes (0) are ignored.
    static func cellAspectRatio(sizes: [(width: Int, height: Int)]) -> CGFloat {
        let known = sizes.filter { $0.width > 0 && $0.height > 0 }
        guard !known.isEmpty else { return defaultAspectRatio }

        // Ratios rounded to a hundredth, so 4000 × 6000 and 4024 × 6048 count as the same shape.
        let ratios = known.map { (Double($0.width) / Double($0.height) * 100).rounded() / 100 }
        let portraits = ratios.filter { $0 < 1 }
        let landscapes = ratios.filter { $0 > 1 }
        let squares = ratios.count - portraits.count - landscapes.count

        if squares > max(portraits.count, landscapes.count) || portraits.count == landscapes.count {
            return 1
        }
        let winners = portraits.count > landscapes.count ? portraits : landscapes
        // The most frequent ratio; on a tie, the larger one, so the result never depends on the order.
        var frequency: [Double: Int] = [:]
        for ratio in winners { frequency[ratio, default: 0] += 1 }
        let mostCommon = frequency.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? defaultAspectRatio
        return CGFloat(min(max(mostCommon, 0.5), 2))
    }

    /// True when a photo fills its cell (edges cropped by at most 5 %), false when it is shown whole
    /// with bands. Cropping more could hide what the AI talks about (« sujet coupé » near an edge),
    /// so a landscape photo in a portrait gallery is shown whole.
    static func fillsCell(photoAspectRatio: CGFloat, cellAspectRatio: CGFloat) -> Bool {
        guard photoAspectRatio > 0, cellAspectRatio > 0 else { return false }
        let difference = max(photoAspectRatio, cellAspectRatio) / min(photoAspectRatio, cellAspectRatio)
        return difference <= 1.05
    }
}

/// Size of the thumbnails: the slider next to the filters and ⌘+ / ⌘− in the « Présentation » menu.
/// The value is the smallest width of a cell, in points; the cells grow to fill each row.
enum ThumbnailSize {
    static let range: ClosedRange<Double> = 120...320
    static let step: Double = 20
    static let standard: Double = 180
    /// The `@AppStorage` key: one size for every gallery.
    static let storageKey = "thumbnailWidth"

    /// One step bigger (`steps` = 1) or smaller (−1), kept within the range and on a step.
    static func zoomed(_ width: Double, steps: Int) -> Double {
        let snapped = ((width - range.lowerBound) / step).rounded() * step + range.lowerBound
        return min(max(snapped + Double(steps) * step, range.lowerBound), range.upperBound)
    }
}
