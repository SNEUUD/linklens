import Foundation

/// Groups photos into bursts. A photo joins the burst of the photo before it when it is close in time
/// AND visually similar (feature-print distance) to that photo, AND still similar to the first photo
/// of the burst, within a few seconds of it. Comparing with the first photo stops a burst from drifting:
/// photo by photo, the same car could go from the trees to the grandstand, two different framings.
enum BurstGrouper {
    /// - Parameters:
    ///   - dates: capture date of each photo, in chronological order (nil if missing).
    ///   - distance: feature-print distance between two photos, by index (nil if unavailable).
    ///     A closure is a function passed as a value, like `(i: number, j: number) => number | null` in TypeScript.
    /// - Returns: runs of consecutive indices forming a burst (only groups of 2+ photos).
    static func group(dates: [Date?], distance: (Int, Int) -> Double?, thresholds: CullingThresholds) -> [[Int]] {
        guard !dates.isEmpty else { return [] }
        var groups: [[Int]] = []
        var current: [Int] = [0]
        for index in dates.indices.dropFirst() {
            if joins(index, burst: current, dates: dates, distance: distance, thresholds: thresholds) {
                current.append(index)
            } else {
                if current.count >= 2 { groups.append(current) }
                current = [index]
            }
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }

    static func joins(
        _ index: Int,
        burst: [Int],
        dates: [Date?],
        distance: (Int, Int) -> Double?,
        thresholds t: CullingThresholds
    ) -> Bool {
        // `burst` is never empty: it holds at least the photo just before `index`.
        let first = burst[0], previous = burst[burst.count - 1]
        guard burst.count < t.burstMaxCount else { return false }
        guard let fromPrevious = distance(previous, index), fromPrevious <= t.burstMaxDistance else { return false }
        if first != previous {
            guard let fromFirst = distance(first, index), fromFirst <= t.burstMaxDistanceFromFirst else { return false }
        }
        // Without dates (e.g. exported JPEGs), similarity alone decides.
        guard let date = dates[index], let previousDate = dates[previous] else { return true }
        guard abs(date.timeIntervalSince(previousDate)) <= t.burstMaxGapSeconds else { return false }
        guard let firstDate = dates[first] else { return true }
        return abs(date.timeIntervalSince(firstDate)) <= t.burstMaxDurationSeconds
    }
}
