import Foundation

/// Groups photos into bursts: two photos that follow each other belong to the same burst
/// when they are close in time AND visually similar (feature-print distance). Reused by F4.
enum BurstGrouper {
    /// - Parameters:
    ///   - secondsApart: gap between photo `i` and `i + 1` (nil if a date is missing). Count = photos − 1.
    ///   - distances: feature-print distance between photo `i` and `i + 1` (nil if unavailable).
    /// - Returns: runs of consecutive indices forming a burst (only groups of 2+ photos).
    static func group(secondsApart: [Double?], distances: [Double?], thresholds: CullingThresholds) -> [[Int]] {
        precondition(secondsApart.count == distances.count)
        var groups: [[Int]] = []
        var current: [Int] = [0]
        for i in secondsApart.indices {
            if shouldLink(secondsApart: secondsApart[i], distance: distances[i], thresholds: thresholds) {
                current.append(i + 1)
            } else {
                if current.count >= 2 { groups.append(current) }
                current = [i + 1]
            }
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }

    static func shouldLink(secondsApart: Double?, distance: Double?, thresholds: CullingThresholds) -> Bool {
        guard let distance, distance <= thresholds.burstMaxDistance else { return false }
        // Without dates (e.g. exported JPEGs), similarity alone decides.
        guard let secondsApart else { return true }
        return abs(secondsApart) <= thresholds.burstMaxGapSeconds
    }
}
