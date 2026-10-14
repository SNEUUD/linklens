import CoreGraphics
import Foundation
import Testing
@testable import LinkLens

// Ported from the LinkLensProbe prototype (Tests/ProbeCoreTests/CullingTests.swift).

private let french = Locale(identifier: "fr_FR")

@Suite("Bursts")
struct BurstGrouperTests {
    let thresholds = CullingThresholds()

    @Test func groupsCloseAndSimilarPhotos() {
        // 0-1-2 close and similar; 2→3: 10 s apart; 3→4: too different.
        let groups = BurstGrouper.group(
            secondsApart: [0.5, 1, 10, 1],
            distances: [0.1, 0.2, 0.1, 0.9],
            thresholds: thresholds
        )
        #expect(groups == [[0, 1, 2]])
    }

    @Test func twoSeparateBursts() {
        let groups = BurstGrouper.group(
            secondsApart: [0, 0, 5, 1],
            distances: [0.1, 0.1, 0.1, 0.1],
            thresholds: thresholds
        )
        #expect(groups == [[0, 1, 2], [3, 4]])
    }

    @Test func missingDateUsesSimilarityOnly() {
        #expect(BurstGrouper.shouldLink(secondsApart: nil, distance: 0.1, thresholds: thresholds))
        #expect(!BurstGrouper.shouldLink(secondsApart: 0, distance: nil, thresholds: thresholds))
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
        let photos = Classifier.classify(
            [makeAnalysis("very", sharpness: 10), makeAnalysis("slightly", sharpness: 60)],
            bursts: [], thresholds: thresholds
        )
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.first?.kind == .blurry)
        #expect(photos[0].reasons.first?.message(locale: french) == "Floue (netteté du sujet 10 < 45)")
        #expect(photos[1].verdict == .review)
        #expect(photos[1].reasons.first?.kind == .slightlyBlurry)
    }

    @Test func subjectCutByTheRightEdge() {
        // Like DSC04317: the car's box stops 1.5 % before the right edge.
        let analysis = makeAnalysis("cut", subject: CGRect(x: 0.48, y: 0.34, width: 0.505, height: 0.22))
        let photos = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.first?.message(locale: french) == "Sujet coupé par le bord droit")
    }

    @Test func subjectTooCloseToTheEdge() {
        let analysis = makeAnalysis("tight", subject: CGRect(x: 0.04, y: 0.4, width: 0.5, height: 0.2))
        let photos = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .review)
        #expect(photos[0].reasons.first?.kind == .subjectTight)
        #expect(photos[0].reasons.first?.message(locale: french) == "Sujet collé au bord gauche (marge 4,0\u{a0}%)")
    }

    @Test func frameFillingSubjectIsNotCut() {
        // A close-up fills the frame: touching the borders is expected.
        let analysis = makeAnalysis("closeup", subject: CGRect(x: 0, y: 0, width: 0.95, height: 1))
        #expect(Classifier.closestEdge(of: analysis.vision.subjectBox!, thresholds) == nil)
        let photos = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .keep)
    }

    @Test func noSubjectMeansNoFramingCheck() {
        let photos = Classifier.classify([makeAnalysis("none", subject: nil)], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .keep)
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

        let results = GalleryCuller.classify(
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
