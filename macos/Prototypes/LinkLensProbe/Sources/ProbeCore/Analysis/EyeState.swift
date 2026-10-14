import CoreGraphics
import Foundation

/// "Eyes closed" estimate. Vision has no such API, so we use a heuristic:
/// openness = eye height / eye width, measured along the eye's own axis
/// (so a tilted head does not distort the result). An open eye is ~0.3, a closed one < 0.15.
public enum EyeState {
    /// Openness of one eye from its contour points, in **pixel** coordinates. Nil if not enough points.
    public static func openness(of points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }

        // 1. Eye width: the two points farthest apart (the corners of the eye).
        var cornerA = points[0], cornerB = points[1], widest = 0.0
        for i in points.indices {
            for j in points.indices where j > i {
                let d = distance(points[i], points[j])
                if d > widest { widest = d; cornerA = points[i]; cornerB = points[j] }
            }
        }
        guard widest > 0 else { return nil }

        // 2. Eye height: spread of the points perpendicular to the corner-to-corner axis.
        let axis = CGPoint(x: (cornerB.x - cornerA.x) / widest, y: (cornerB.y - cornerA.y) / widest)
        let perpendicular = points.map { Double(($0.x - cornerA.x) * -axis.y + ($0.y - cornerA.y) * axis.x) }
        let height = (perpendicular.max() ?? 0) - (perpendicular.min() ?? 0)
        return height / widest
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }
}
