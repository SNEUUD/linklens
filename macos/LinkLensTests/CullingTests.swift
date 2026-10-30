import CoreGraphics
import Foundation
import Testing
@testable import LinkLens

// Ported from the LinkLensProbe prototype (Tests/ProbeCoreTests/CullingTests.swift).

private let french = Locale(identifier: "fr_FR")

@Suite("Bursts")
struct BurstGrouperTests {
    let thresholds = CullingThresholds()
    let start = Date(timeIntervalSince1970: 1_780_000_000)

    /// Dates from seconds after `start` (nil = no date).
    func dates(_ seconds: [Double?]) -> [Date?] {
        seconds.map { $0.map { start.addingTimeInterval($0) } }
    }

    /// Distance from a table of every pair (symmetric): `table[i][j]`.
    func distances(_ table: [[Double]]) -> (Int, Int) -> Double? {
        { i, j in table[min(i, j)][max(i, j)] }
    }

    /// Every photo at `distance` from every other one.
    func uniform(_ count: Int, _ distance: Double) -> (Int, Int) -> Double? {
        { _, _ in distance }
    }

    @Test func groupsCloseAndSimilarPhotos() {
        // 0-1-2 close and similar; 2→3: 10 s apart; 3→4: too different.
        let table = [
            [0, 0.1, 0.2, 0.9, 0.9],
            [0, 0, 0.2, 0.9, 0.9],
            [0, 0, 0, 0.1, 0.9],
            [0, 0, 0, 0, 0.9],
        ]
        let groups = BurstGrouper.group(dates: dates([0, 0.5, 1.5, 11.5, 12.5]), distance: distances(table), thresholds: thresholds)
        #expect(groups == [[0, 1, 2]])
    }

    @Test func twoSeparateBursts() {
        let groups = BurstGrouper.group(dates: dates([0, 0, 0, 5, 6]), distance: uniform(5, 0.1), thresholds: thresholds)
        #expect(groups == [[0, 1, 2], [3, 4]])
    }

    @Test func nearIdenticalPairStaysTogether() {
        let groups = BurstGrouper.group(dates: dates([0, 1]), distance: uniform(2, 0.05), thresholds: thresholds)
        #expect(groups == [[0, 1]])
    }

    @Test func driftingBurstIsSplit() {
        // Each photo looks like the one before (0.2), but the framing drifts away from the first one:
        // the same car, first in front of the trees, then in front of the grandstand.
        let groups = BurstGrouper.group(
            dates: dates([0, 0, 0, 0, 1, 1]),
            distance: { i, j in Double(abs(i - j)) * 0.2 },
            thresholds: thresholds
        )
        // 0→2 is 0.4 > 0.35 from the first photo: a new burst starts at 2, then at 4.
        #expect(groups == [[0, 1], [2, 3], [4, 5]])
    }

    @Test func burstLastsAtMostTwoSeconds() {
        // One photo per second, all alike (a fixed camera, cars passing one after the other).
        let groups = BurstGrouper.group(dates: dates([0, 1, 2, 3, 4, 5]), distance: uniform(6, 0.1), thresholds: thresholds)
        #expect(groups == [[0, 1, 2], [3, 4, 5]])
    }

    @Test func burstHasAMaximumSize() {
        let count = thresholds.burstMaxCount + 5
        let groups = BurstGrouper.group(
            dates: dates(Array(repeating: 0, count: count)), distance: uniform(count, 0.1), thresholds: thresholds
        )
        #expect(groups.map(\.count) == [thresholds.burstMaxCount, 5])
    }

    @Test func missingDateUsesSimilarityOnly() {
        #expect(BurstGrouper.group(dates: dates([nil, nil]), distance: uniform(2, 0.1), thresholds: thresholds) == [[0, 1]])
        #expect(BurstGrouper.group(dates: dates([0, 0]), distance: { _, _ in nil }, thresholds: thresholds).isEmpty)
    }
}

@Suite("Classification")
struct ClassifierTests {
    let thresholds = CullingThresholds()

    @Test func sharpPhotoIsKeptWithAReason() {
        let photos = Classifier.classify([makeAnalysis("a")], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .keep)
        #expect(photos[0].reasons.map(\.kind) == [.noIssue])
    }

    @Test func blurLevels() {
        // A small gallery (under 20 photos) is judged on the scores alone.
        let photos = Classifier.classify(
            [makeAnalysis("very", sharpness: 10), makeAnalysis("slightly", sharpness: 45), makeAnalysis("sharp", sharpness: 80)],
            bursts: [], thresholds: thresholds
        )
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.first?.kind == .blurry)
        #expect(photos[0].reasons.first?.message(locale: french) == "Floue (netteté du sujet 10 < 42)")
        #expect(photos[1].verdict == .review)
        #expect(photos[1].reasons.first?.kind == .slightlyBlurry)
        #expect(photos[2].verdict == .keep)
    }

    @Test func blurIsJudgedAgainstTheGallery() {
        // 1 blurry photo among 29 sharp ones: among the least sharp, so "Rejeter".
        let sharpGallery = [makeAnalysis("blurry", sharpness: 30)] + (1..<30).map { makeAnalysis("p\($0)", sharpness: 80) }
        let first = Classifier.classify(sharpGallery, bursts: [], thresholds: thresholds)[0]
        #expect(first.verdict == .reject)
        #expect(first.reasons.first?.message(locale: french) == "Floue (netteté du sujet 30, parmi les 4\u{a0}% les moins nettes)")

        // A night gallery where every photo scores 30: none is among the least sharp, "À revoir" at most.
        let nightGallery = (0..<30).map { makeAnalysis("n\($0)", sharpness: 30) }
        let night = Classifier.classify(nightGallery, bursts: [], thresholds: thresholds)
        #expect(night.allSatisfy { $0.verdict != .reject })
        #expect(night.filter { $0.reasons.first?.kind == .blurry }.count == 30)
    }

    @Test func slightBlurOnlyForTheLeastSharpOfTheGallery() {
        // 45 is under `blurReview`, but most of the gallery is softer: nothing to say.
        let gallery = [makeAnalysis("a", sharpness: 45)] + (1..<30).map { makeAnalysis("p\($0)", sharpness: 44) }
        #expect(Classifier.classify(gallery, bursts: [], thresholds: thresholds)[0].verdict == .keep)
    }

    @Test func blurrySubjectWithSharpSurroundingsIsOnlyReview() {
        // A blurry spectator in front of a sharp car: the focus is elsewhere, maybe on purpose.
        let photo = makeAnalysis("spectator", sharpness: 30, surroundingSharpness: 70)
        let result = Classifier.classify([photo], bursts: [], thresholds: thresholds)[0]
        #expect(result.verdict == .review)
        #expect(result.reasons.first?.kind == .blurry)
    }

    @Test func wholeImageIsRejectedOnlyWhenClearlyBlurry() {
        // No subject found: the background of a panning shot may be blurred on purpose.
        let panning = makeAnalysis("panning", sharpness: 38, subject: nil)
        let blurred = makeAnalysis("blurred", sharpness: 30, subject: nil)
        let results = Classifier.classify([panning, blurred], bursts: [], thresholds: thresholds)
        #expect(results.map(\.verdict) == [.review, .reject])
        #expect(results[1].reasons.first?.message(locale: french) == "Floue (netteté de l'image 30 < 35)")
    }

    @Test func photoWithNothingToJudgeIsNotCalledBlurry() {
        let empty = makeAnalysis("sky", sharpness: 0, detailedZones: 0)
        #expect(Classifier.classify([empty], bursts: [], thresholds: thresholds)[0].verdict == .keep)
    }

    @Test func smallIsolatedSubjectCutByTheRightEdgeIsOnlyReview() {
        // Like DSC04317: the car's box stops at the right edge. Never "Rejeter" for framing.
        let analysis = makeAnalysis("cut", subject: CGRect(x: 0.5, y: 0.34, width: 0.495, height: 0.22))
        let photos = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .review)
        #expect(photos[0].reasons.first?.kind == .subjectCut)
        #expect(photos[0].reasons.first?.message(locale: french) == "Sujet coupé par le bord droit")
    }

    @Test func subjectCloseToTheEdgeButInsideIsFine() {
        let analysis = makeAnalysis("tight", subject: CGRect(x: 0.04, y: 0.4, width: 0.5, height: 0.2))
        #expect(Classifier.classify([analysis], bursts: [], thresholds: thresholds)[0].verdict == .keep)
    }

    @Test func detailFillingTheFrameIsNotCut() {
        // A wheel or a badge shot up close: 45 % of the image, touching the border on purpose.
        let detail = makeAnalysis("wheel", subject: CGRect(x: 0, y: 0.2, width: 0.75, height: 0.6))
        #expect(Classifier.framingReason(detail.vision.salientObjects, thresholds) == nil)
        #expect(Classifier.classify([detail], bursts: [], thresholds: thresholds)[0].verdict == .keep)
    }

    @Test func sceneWithSeveralSubjectsIsNotCut() {
        // Car show: the largest car touches the border, another car stands next to it.
        let show = makeAnalysis(
            "show",
            subject: CGRect(x: 0, y: 0.4, width: 0.4, height: 0.3),
            others: [SalientObject(box: CGRect(x: 0.5, y: 0.45, width: 0.3, height: 0.2), confidence: 0.6)]
        )
        #expect(Classifier.framingReason(show.vision.salientObjects, thresholds) == nil)
    }

    @Test func onlyTheSidesAreChecked() {
        // A spectator's back touching the bottom: foreground, not a cut subject.
        let foreground = makeAnalysis("spectator", subject: CGRect(x: 0.4, y: 0.75, width: 0.2, height: 0.25))
        #expect(Classifier.framingReason(foreground.vision.salientObjects, thresholds) == nil)
    }

    @Test func unsureSubjectBoxIsNotChecked() {
        let fence = makeAnalysis("fence", subject: CGRect(x: 0.7, y: 0.5, width: 0.3, height: 0.2), subjectConfidence: 0.35)
        #expect(Classifier.framingReason(fence.vision.salientObjects, thresholds) == nil)
    }

    @Test func noSubjectMeansNoFramingCheck() {
        let photos = Classifier.classify([makeAnalysis("none", subject: nil)], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .keep)
    }

    @Test func nearlyBlackPhotoIsRejected() {
        let photos = Classifier.classify(
            [makeAnalysis("black", shadows: 0.999), makeAnalysis("night", shadows: 0.9)],
            bursts: [], thresholds: thresholds
        )
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.first?.message(locale: french) == "Presque entièrement noire (100\u{a0}% de pixels noirs)")
        #expect(photos[1].verdict == .review)
        #expect(photos[1].reasons.first?.kind == .underexposed)
    }

    @Test func bestOfABurstOfBlackFramesKeepsItsOwnFlaws() {
        // Every frame is black: the "best" one is no better, it stays rejected.
        let frames = (0..<3).map { makeAnalysis("frame\($0)", sharpness: 100 - Double($0), shadows: 0.999) }
        let photos = Classifier.classify(frames, bursts: [[0, 1, 2]], thresholds: thresholds)
        #expect(photos[0].isBestOfBurst)
        #expect(photos.allSatisfy { $0.verdict == .reject })
        #expect(photos[0].reasons.map(\.kind) == [.nearlyBlack, .bestOfBurst])
    }

    @Test func mostSevereReasonComesFirst() {
        let analysis = makeAnalysis("a", aesthetics: -0.8, highlights: 0.5)
        let photos = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.map(\.kind) == [.overexposed, .lowAesthetics])
    }

    @Test func eyesClosedIsOnlyReview() {
        let photos = Classifier.classify(
            [makeAnalysis("a", faces: [face(eyesClosed: true), face(eyesClosed: nil)])],
            bursts: [], thresholds: thresholds
        )
        #expect(photos[0].verdict == .review)
        #expect(photos[0].reasons.first?.message(locale: french) == "Yeux fermés (1 visage)")
    }

    @Test func burstBestRunnerUpAndLoser() {
        let analyses = [
            makeAnalysis("best", sharpness: 900),
            makeAnalysis("almost", sharpness: 850),
            makeAnalysis("worse", sharpness: 150, aesthetics: -0.2),
        ]
        let photos = Classifier.classify(analyses, bursts: [[0, 1, 2]], thresholds: thresholds)
        #expect(photos[0].isBestOfBurst && photos[0].verdict == .keep)
        #expect(photos[0].reasons.map(\.kind) == [.bestOfBurst])
        #expect(photos[1].verdict == .review && photos[1].reasons.first?.kind == .burstRunnerUp)
        #expect(photos[2].verdict == .reject && photos[2].reasons.first?.kind == .burstLoser)
        #expect(photos[2].reasons.first?.message(locale: french) == "Moins bonne de la rafale (meilleure : best)")
        #expect(photos.allSatisfy { $0.burstNumber == 1 })
    }

    @Test func eyesOpenWinsInABurst() {
        let analyses = [
            makeAnalysis("closed", faces: [face(quality: 0.5, eyesClosed: true)]),
            makeAnalysis("open", faces: [face(quality: 0.5, eyesClosed: false)]),
        ]
        let photos = Classifier.classify(analyses, bursts: [[0, 1]], thresholds: thresholds)
        #expect(photos[1].isBestOfBurst)
    }

    @Test func burstWithoutFacesIgnoresFaceCriteria() {
        // Only sharpness (0.45) and aesthetics (0.25) count: (0.45 × √(400/900) + 0.25 × 1) / 0.70.
        let scores = Classifier.burstScoresOf(
            [makeAnalysis("a", sharpness: 900), makeAnalysis("b", sharpness: 400)],
            thresholds
        )
        #expect(scores[0] == 1)
        #expect(abs(scores[1] - (0.45 * (2.0 / 3.0) + 0.25) / 0.70) < 0.0001)
    }

    @Test func normalizationWithoutValues() {
        #expect(Classifier.normalized([nil, nil]) == nil)
        #expect(Classifier.normalized([0, 0]) == [1, 1])
        #expect(Classifier.normalized([2, nil, 4]) == [0.5, 0, 1])
    }

    @Test func photosAreClassifiedInChronologicalOrder() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let late = makeAnalysis("DSC2.ARW", date: start.addingTimeInterval(5))
        let early = makeAnalysis("DSC10.ARW", date: start)
        let sameSecond = makeAnalysis("DSC3.ARW", date: start.addingTimeInterval(5))
        let undated = makeAnalysis("IMG.JPG", date: nil)
        let failedId = UUID()

        let results = Classifier.classifyGallery(
            analyses: [undated, late, sameSecond, early],
            failedPhotoIds: [failedId],
            thresholds: thresholds
        )
        // Date first, then the file name in natural order (DSC2 before DSC3), undated photos last.
        #expect(results.map(\.photoId) == [early, late, sameSecond, undated].map(\.photo.id) + [failedId])
        #expect(results.last?.verdict == .review)
        #expect(results.last?.reasons.map(\.kind) == [.analysisFailed])
    }
}

@Suite("Stored reasons")
struct CullingReasonTests {
    @Test func reasonsSurviveAJSONRoundTrip() throws {
        let reasons = [
            CullingReason(kind: .subjectTight, verdict: .review, value: 0.041, side: .left),
            CullingReason(kind: .burstLoser, verdict: .reject, bestPhoto: "DSC04298.ARW"),
        ]
        let decoded = try JSONDecoder().decode([CullingReason].self, from: JSONEncoder().encode(reasons))
        #expect(decoded == reasons)
    }

    @Test func unknownValuesFromANewerVersionDoNotBreakDecoding() throws {
        let json = #"[{ "kind": "tooManyCats", "verdict": "maybe" }]"#
        let decoded = try JSONDecoder().decode([CullingReason].self, from: Data(json.utf8))
        #expect(decoded == [CullingReason(kind: .unknown, verdict: .unknown)])
    }
}
