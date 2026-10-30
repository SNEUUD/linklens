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
    /// What the analysis measured anyway, stored for the inspector (nil for an unreadable photo).
    /// Not used to choose the verdict: that is `reasons`.
    var measured: PhotoDetails.Measured? = nil
    var capture: CaptureInfo? = nil
}

/// Turns measurements into Garder / À revoir / Rejeter, always with the reasons.
/// Exact duplicates are left to F5.
enum Classifier {
    /// Chronological order, bursts, then verdicts. Needs every photo of the gallery (bursts, and blur
    /// is judged against the rest of the gallery), so it runs once the analysis is done.
    static func classifyGallery(analyses: [PhotoAnalysis], failedPhotoIds: [UUID], thresholds: CullingThresholds) -> [CullingResult] {
        // Chronological order (file name breaks ties: the A6000 has no sub-seconds).
        let sorted = analyses.sorted { a, b in
            let dateA = a.photo.captureDate ?? .distantFuture
            let dateB = b.photo.captureDate ?? .distantFuture
            if dateA != dateB { return dateA < dateB }
            return a.photo.relativePath.localizedStandardCompare(b.photo.relativePath) == .orderedAscending
        }
        let bursts = BurstGrouper.group(
            dates: sorted.map(\.photo.captureDate),
            distance: { i, j in
                guard let a = sorted[i].vision.featurePrint, let b = sorted[j].vision.featurePrint else { return nil }
                return try? a.distance(to: b)
            },
            thresholds: thresholds
        )
        return classify(sorted, bursts: bursts, thresholds: thresholds)
            + failedPhotoIds.map { failedResult(photoId: $0) }
    }

    /// - Parameters:
    ///   - analyses: photos in chronological order.
    ///   - bursts: groups of indices into `analyses` (from `BurstGrouper`).
    /// - Returns: one result per analysis, in the same order.
    static func classify(_ analyses: [PhotoAnalysis], bursts: [[Int]], thresholds: CullingThresholds) -> [CullingResult] {
        let gallery = GallerySharpness(analyses.map(\.sharpness))
        // Each photo is first judged on its own flaws; a burst rank can only add to them
        // (the best photo of a burst of black frames stays rejected).
        var reasons = analyses.map { photoReasons($0, thresholds, gallery: gallery) }
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
                aesthetics: analysis.vision.aesthetics,
                measured: PhotoDetails.Measured(
                    subjectBox: analysis.vision.subjectBox,
                    highlightClipping: analysis.exposure.highlightClipping,
                    shadowClipping: analysis.exposure.shadowClipping
                ),
                capture: analysis.capture
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

    static func photoReasons(_ analysis: PhotoAnalysis, _ t: CullingThresholds, gallery: GallerySharpness? = nil) -> [CullingReason] {
        var reasons: [CullingReason] = []
        if let blur = blurReason(analysis.sharpness, t, gallery: gallery) {
            reasons.append(blur)
        }
        if let cut = framingReason(analysis.vision.salientObjects, t) {
            reasons.append(cut)
        }

        let highlights = analysis.exposure.highlightClipping
        if highlights > t.highlightReject {
            reasons.append(CullingReason(kind: .overexposed, verdict: .reject, value: highlights))
        } else if highlights > t.highlightReview {
            reasons.append(CullingReason(kind: .slightlyOverexposed, verdict: .review, value: highlights))
        }
        let shadows = analysis.exposure.shadowClipping
        if shadows > t.shadowReject {
            reasons.append(CullingReason(kind: .nearlyBlack, verdict: .reject, value: shadows))
        } else if shadows > t.shadowReview {
            reasons.append(CullingReason(kind: .underexposed, verdict: .review, value: shadows))
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

    // MARK: - Blur

    /// Blurry only when the score is low on its own AND among the lowest of the gallery: a clearly
    /// blurry photo ("Rejeter") is under `blurReject` (`blurRejectWithoutSubject` without a subject),
    /// in the least sharp `blurRejectGalleryShare`, and nothing around its subject is sharp either.
    /// A photo with nothing to judge (black frame, empty sky) gets no blur verdict.
    static func blurReason(_ sharpness: SharpnessMeasurement, _ t: CullingThresholds, gallery: GallerySharpness?) -> CullingReason? {
        guard sharpness.isMeasurable, sharpness.sharpness < t.blurReview else { return nil }
        let score = sharpness.sharpness
        // nil when the gallery is too small to compare: the score alone decides.
        let share = gallery.flatMap { $0.count >= t.blurMinGalleryForShare ? $0.shareBelow(score) : nil }
        func isAmongLeastSharp(_ limit: Double) -> Bool { share.map { $0 <= limit } ?? true }

        let rejectBelow = sharpness.measuredOnSubject ? t.blurReject : t.blurRejectWithoutSubject
        if score < rejectBelow {
            // A sharp photo around a blurry subject: the focus may be on purpose elsewhere. Let the user decide.
            let isSharpElsewhere = sharpness.surroundingSharpness >= t.blurSharpAround
            let verdict: CullingVerdict = isAmongLeastSharp(t.blurRejectGalleryShare) && !isSharpElsewhere ? .reject : .review
            return CullingReason(kind: .blurry, verdict: verdict, value: score, threshold: rejectBelow,
                                 onSubject: sharpness.measuredOnSubject, galleryShare: share)
        }
        guard isAmongLeastSharp(t.blurReviewGalleryShare) else { return nil }
        return CullingReason(kind: .slightlyBlurry, verdict: .review, value: score, threshold: t.blurReview,
                             onSubject: sharpness.measuredOnSubject, galleryShare: share)
    }

    // MARK: - Framing

    /// "Sujet coupé" ("À revoir" only, never "Rejeter"): only for a small, isolated main subject that
    /// touches the left or right border, like a car leaving the frame. A detail that fills the frame, or a
    /// scene with several subjects (car show, people in front), is framed on purpose. The top and bottom
    /// are not checked: there the box mostly meets the sky or a foreground (grass, spectators).
    static func framingReason(_ objects: [SalientObject], _ t: CullingThresholds) -> CullingReason? {
        guard let main = objects.first,
              main.area <= t.framingMaxSubjectArea,
              main.confidence >= t.framingMinConfidence,
              main.box.width <= t.framingMaxSubjectWidth else { return nil }
        let hasOtherSubject = objects.dropFirst().contains { $0.area >= main.area * t.framingOtherSubjectShare }
        guard !hasOtherSubject else { return nil }
        let left = Double(main.box.minX), right = Double(1 - main.box.maxX)
        let (side, margin): (FrameSide, Double) = left <= right ? (.left, left) : (.right, right)
        guard margin < t.subjectCutMargin else { return nil }
        return CullingReason(kind: .subjectCut, verdict: .review, value: margin, side: side)
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

/// The sharpness scores of a whole gallery, to tell how a photo compares with the others.
struct GallerySharpness: Sendable {
    /// Measurable scores only, sorted from the least sharp.
    private let sorted: [Double]

    init(_ measurements: [SharpnessMeasurement]) {
        sorted = measurements.filter(\.isMeasurable).map(\.sharpness).sorted()
    }

    var count: Int { sorted.count }

    /// Share of the gallery (0…1) at most as sharp as `score`: 0.05 = among the 5 % least sharp.
    func shareBelow(_ score: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        // Binary search: index of the first score above `score`.
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] <= score { low = middle + 1 } else { high = middle }
        }
        return Double(low) / Double(sorted.count)
    }
}
