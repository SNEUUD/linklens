import CoreGraphics
import Foundation

/// Verdict of one photo, ready to be stored on its `Photo`.
struct CullingResult: Sendable, Equatable {
    var photoId: UUID
    var verdict: CullingVerdict
    /// Most severe first: the first one is the main reason shown in the gallery.
    var reasons: [CullingReason]
    /// Number of the burst in the gallery (1, 2…), nil if the photo is not part of a burst.
    var burstNumber: Int?
    var isBestOfBurst = false
    var sharpness: Double?
    var aesthetics: Double?
}

/// Turns measurements into Garder / À revoir / Rejeter, always with the reasons.
/// Same rules as the validated LinkLensProbe prototype (without exact duplicates, which belong to F5).
enum Classifier {
    /// - Parameters:
    ///   - analyses: photos in chronological order.
    ///   - bursts: groups of indices into `analyses` (from `BurstGrouper`).
    /// - Returns: one result per analysis, in the same order.
    static func classify(_ analyses: [PhotoAnalysis], bursts: [[Int]], thresholds: CullingThresholds) -> [CullingResult] {
        var reasons = analyses.map { photoReasons($0, thresholds) }
        var burstNumbers = [Int?](repeating: nil, count: analyses.count)
        var bestOfBurst = [Bool](repeating: false, count: analyses.count)

        // Bursts: the best photo stays, the others are compared to it.
        for (offset, members) in bursts.enumerated() {
            let number = offset + 1
            let scores = burstScoresOf(members.map { analyses[$0] }, thresholds)
            // max(by:) keeps the first of equal elements when we compare with `<`.
            let bestPosition = scores.indices.max { scores[$0] < scores[$1] } ?? 0
            let bestIndex = members[bestPosition]
            let bestScore = scores[bestPosition]
            let bestName = analyses[bestIndex].photo.relativePath

            for (position, index) in members.enumerated() {
                burstNumbers[index] = number
                guard index != bestIndex else { bestOfBurst[index] = true; continue }
                let ratio = bestScore > 0 ? scores[position] / bestScore : 1
                if ratio >= thresholds.burstRunnerUpRatio {
                    reasons[index].append(CullingReason(kind: .burstRunnerUp, verdict: .review, bestPhoto: bestName))
                } else {
                    reasons[index].append(CullingReason(kind: .burstLoser, verdict: .reject, bestPhoto: bestName))
                }
            }
        }

        return analyses.indices.map { index in
            let analysis = analyses[index]
            // Most severe first; `sorted` keeps the insertion order for equal severities.
            var sorted = reasons[index].sorted { $0.verdict.severity > $1.verdict.severity }
            if bestOfBurst[index] {
                sorted.append(CullingReason(kind: .bestOfBurst, verdict: .keep))
            }
            if sorted.isEmpty {
                sorted.append(CullingReason(kind: .noIssue, verdict: .keep))
            }
            return CullingResult(
                photoId: analysis.photo.id,
                verdict: sorted[0].verdict,
                reasons: sorted,
                burstNumber: burstNumbers[index],
                isBestOfBurst: bestOfBurst[index],
                sharpness: analysis.sharpness.sharpness,
                aesthetics: analysis.vision.aesthetics
            )
        }
    }

    /// A photo that could not be read still gets a verdict and a reason.
    static func failedResult(photoId: UUID) -> CullingResult {
        CullingResult(
            photoId: photoId,
            verdict: .review,
            reasons: [CullingReason(kind: .analysisFailed, verdict: .review)]
        )
    }

    // MARK: - Per-photo criteria

    static func photoReasons(_ analysis: PhotoAnalysis, _ t: CullingThresholds) -> [CullingReason] {
        var reasons: [CullingReason] = []
        let sharpness = analysis.sharpness.sharpness
        let onSubject = analysis.sharpness.measuredOnSubject
        if sharpness < t.blurReject {
            reasons.append(CullingReason(kind: .blurry, verdict: .reject,
                                         value: sharpness, threshold: t.blurReject, onSubject: onSubject))
        } else if sharpness < t.blurReview {
            reasons.append(CullingReason(kind: .slightlyBlurry, verdict: .review,
                                         value: sharpness, threshold: t.blurReview, onSubject: onSubject))
        }

        if let subject = analysis.vision.subjectBox, let edge = closestEdge(of: subject, t) {
            if edge.margin < t.subjectCutMargin {
                reasons.append(CullingReason(kind: .subjectCut, verdict: .reject, value: edge.margin, side: edge.side))
            } else if edge.margin < t.subjectTightMargin {
                reasons.append(CullingReason(kind: .subjectTight, verdict: .review, value: edge.margin, side: edge.side))
            }
        }

        let highlights = analysis.exposure.highlightClipping
        if highlights > t.highlightReject {
            reasons.append(CullingReason(kind: .overexposed, verdict: .reject, value: highlights))
        } else if highlights > t.highlightReview {
            reasons.append(CullingReason(kind: .slightlyOverexposed, verdict: .review, value: highlights))
        }
        if analysis.exposure.shadowClipping > t.shadowReview {
            reasons.append(CullingReason(kind: .underexposed, verdict: .review, value: analysis.exposure.shadowClipping))
        }

        // Eyes are not validated on real portraits yet: "À revoir" at most.
        let closedFaces = analysis.vision.faces.filter { $0.eyesClosed == true }.count
        if closedFaces > 0 {
            reasons.append(CullingReason(kind: .eyesClosed, verdict: .review, count: closedFaces))
        }

        if let aesthetics = analysis.vision.aesthetics, aesthetics < t.aestheticsReview {
            reasons.append(CullingReason(kind: .lowAesthetics, verdict: .review, value: aesthetics))
        }
        if analysis.vision.isUtility == true {
            reasons.append(CullingReason(kind: .utility, verdict: .review))
        }
        return reasons
    }

    // MARK: - Framing

    /// The image border closest to the subject, ignoring an axis where the subject fills the frame
    /// (a close-up portrait legitimately touches the top and bottom).
    static func closestEdge(of subject: CGRect, _ t: CullingThresholds) -> (side: FrameSide, margin: Double)? {
        var margins: [(side: FrameSide, margin: Double)] = []
        if subject.width <= t.framingMaxSubjectSize {
            margins += [(.left, Double(subject.minX)), (.right, Double(1 - subject.maxX))]
        }
        if subject.height <= t.framingMaxSubjectSize {
            margins += [(.top, Double(subject.minY)), (.bottom, Double(1 - subject.maxY))]
        }
        return margins.min { $0.margin < $1.margin }
    }

    // MARK: - Burst score

    /// Score of each burst member (0…1). Each criterion is divided by the best value in the burst,
    /// so near-identical photos get near-identical scores.
    /// A criterion nobody in the burst has (e.g. faces in a car photo) is left out entirely,
    /// otherwise it would give everyone the same points and hide the real differences.
    static func burstScoresOf(_ members: [PhotoAnalysis], _ t: CullingThresholds) -> [Double] {
        let hasFaces = members.contains { !$0.vision.faces.isEmpty }
        let criteria: [(weight: Double, values: [Double]?)] = [
            // sqrt: the Laplacian variance grows with the square of edge strength.
            (t.burstWeightSharpness, normalized(members.map { sqrt($0.sharpness.sharpness) })),
            (t.burstWeightAesthetics, normalized(members.map { $0.vision.aesthetics.map { ($0 + 1) / 2 } })),
            (t.burstWeightFaceQuality, normalized(members.map { member -> Double? in
                let values = member.vision.faces.compactMap(\.captureQuality)
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            })),
            (t.burstWeightEyesOpen, hasFaces ? normalized(members.map { member -> Double? in
                let faces = member.vision.faces
                guard !faces.isEmpty else { return nil }
                return Double(faces.filter { $0.eyesClosed != true }.count) / Double(faces.count)
            }) : nil),
        ]

        let used = criteria.compactMap { criterion in criterion.values.map { (weight: criterion.weight, values: $0) } }
        let totalWeight = used.reduce(0) { $0 + $1.weight }
        return members.indices.map { i in
            guard totalWeight > 0 else { return 1 }
            return used.reduce(0) { $0 + $1.weight * $1.values[i] } / totalWeight
        }
    }

    /// Divides each value by the max; missing values count as 0.
    /// Nil if nobody has a value (the criterion is then ignored).
    static func normalized(_ values: [Double?]) -> [Double]? {
        let present = values.compactMap { $0 }
        guard let maximum = present.max() else { return nil }
        guard maximum > 0 else { return values.map { _ in 1 } }
        return values.map { ($0 ?? 0) / maximum }
    }
}
