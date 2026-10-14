import Foundation

/// Turns measurements into Garder / À revoir / Rejeter, always with the reasons.
public enum Classifier {
    /// - Parameters:
    ///   - analyses: photos in chronological order.
    ///   - bursts: groups of indices into `analyses` (from `BurstGrouper`).
    public static func classify(
        _ analyses: [PhotoAnalysis],
        bursts: [[Int]],
        thresholds: Thresholds
    ) -> (photos: [PhotoResult], bursts: [Burst]) {
        var reasons = analyses.map { photoReasons($0, thresholds) }
        var burstIds = [Int?](repeating: nil, count: analyses.count)
        var burstScores = [Double?](repeating: nil, count: analyses.count)
        var bestOfBurst = [Bool](repeating: false, count: analyses.count)
        var burstSummaries: [Burst] = []

        // Exact duplicates: same SHA-256. The first one (chronological order) is kept.
        var firstWithHash: [String: Int] = [:]
        for (index, analysis) in analyses.enumerated() {
            if let original = firstWithHash[analysis.sha256] {
                reasons[index].append(Reason(
                    code: .exactDuplicate, verdict: .reject,
                    message: "Doublon exact de \(analyses[original].file.relativePath)"
                ))
            } else {
                firstWithHash[analysis.sha256] = index
            }
        }

        // Bursts: the best photo stays, the others are compared to it.
        for (number, members) in bursts.enumerated() {
            let id = number + 1
            let scores = burstScoresOf(members.map { analyses[$0] }, thresholds)
            // max(by:) keeps the first of equal elements when we compare with `<`.
            let bestPosition = scores.indices.max { scores[$0] < scores[$1] } ?? 0
            let bestIndex = members[bestPosition]
            let bestScore = scores[bestPosition]
            let bestName = analyses[bestIndex].file.relativePath

            for (position, index) in members.enumerated() {
                burstIds[index] = id
                burstScores[index] = scores[position]
                guard index != bestIndex else { bestOfBurst[index] = true; continue }
                let ratio = bestScore > 0 ? scores[position] / bestScore : 1
                if ratio >= thresholds.burstRunnerUpRatio {
                    reasons[index].append(Reason(
                        code: .burstRunnerUp, verdict: .review,
                        message: "Presque aussi bonne que \(bestName), la meilleure de la rafale"
                    ))
                } else {
                    reasons[index].append(Reason(
                        code: .burstLoser, verdict: .reject,
                        message: "Moins bonne de la rafale (meilleure : \(bestName))"
                    ))
                }
            }
            burstSummaries.append(Burst(id: id, photos: members.map { analyses[$0].file.relativePath }, best: bestName))
        }

        let results = analyses.enumerated().map { index, analysis in
            let sorted = reasons[index].sorted { $0.verdict > $1.verdict } // stable: keeps insertion order for ties
            return PhotoResult(
                fileName: analysis.file.url.lastPathComponent,
                relativePath: analysis.file.relativePath,
                fileSize: analysis.file.fileSize,
                sha256: analysis.sha256,
                captureDate: analysis.metadata.captureDate,
                pixelWidth: analysis.metadata.pixelWidth,
                pixelHeight: analysis.metadata.pixelHeight,
                previewSource: analysis.previewSource,
                aesthetics: analysis.vision.aesthetics,
                isUtility: analysis.vision.isUtility,
                faces: analysis.vision.faces,
                sharpness: analysis.sharpness.sharpness,
                globalSharpness: analysis.sharpness.globalSharpness,
                highlightClipping: analysis.exposure.highlightClipping,
                shadowClipping: analysis.exposure.shadowClipping,
                burstId: burstIds[index],
                isBestOfBurst: bestOfBurst[index],
                burstScore: burstScores[index],
                verdict: sorted.first?.verdict ?? .keep,
                reasons: sorted,
                thumbnail: analysis.thumbnail
            )
        }
        return (results, burstSummaries)
    }

    // MARK: - Per-photo criteria

    static func photoReasons(_ analysis: PhotoAnalysis, _ t: Thresholds) -> [Reason] {
        var reasons: [Reason] = []
        let sharpness = analysis.sharpness.sharpness
        if sharpness < t.blurReject {
            reasons.append(Reason(code: .blurry, verdict: .reject,
                                  message: "Floue (netteté \(format(sharpness)) < \(format(t.blurReject)))"))
        } else if sharpness < t.blurReview {
            reasons.append(Reason(code: .slightlyBlurry, verdict: .review,
                                  message: "Légèrement floue (netteté \(format(sharpness)) < \(format(t.blurReview)))"))
        }

        let highlights = analysis.exposure.highlightClipping
        if highlights > t.highlightReject {
            reasons.append(Reason(code: .overexposed, verdict: .reject,
                                  message: "Très surexposée (\(percent(highlights)) de pixels brûlés)"))
        } else if highlights > t.highlightReview {
            reasons.append(Reason(code: .slightlyOverexposed, verdict: .review,
                                  message: "Hautes lumières brûlées (\(percent(highlights)) des pixels)"))
        }
        if analysis.exposure.shadowClipping > t.shadowReview {
            reasons.append(Reason(code: .underexposed, verdict: .review,
                                  message: "Sous-exposée (\(percent(analysis.exposure.shadowClipping)) de pixels noirs)"))
        }

        let closedFaces = analysis.vision.faces.filter { $0.eyesClosed == true }.count
        if closedFaces > 0 {
            let subject = closedFaces == 1 ? "1 visage" : "\(closedFaces) visages"
            reasons.append(Reason(code: .eyesClosed, verdict: .review, message: "Yeux fermés (\(subject))"))
        }

        if let aesthetics = analysis.vision.aesthetics, aesthetics < t.aestheticsReview {
            reasons.append(Reason(code: .lowAesthetics, verdict: .review,
                                  message: "Score esthétique faible (\(format(aesthetics, digits: 2)))"))
        }
        if analysis.vision.isUtility == true {
            reasons.append(Reason(code: .utility, verdict: .review,
                                  message: "Photo utilitaire (document, capture d'écran…)"))
        }
        return reasons
    }

    // MARK: - Burst score

    /// Score of each burst member (0…1). Each criterion is divided by the best value in the burst,
    /// so near-identical photos get near-identical scores.
    /// A criterion nobody in the burst has (e.g. faces in a car photo) is left out entirely,
    /// otherwise it would give everyone the same points and hide the real differences.
    static func burstScoresOf(_ members: [PhotoAnalysis], _ t: Thresholds) -> [Double] {
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

    private static func format(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "fr_FR")))
    }

    private static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "fr_FR")))
    }
}
