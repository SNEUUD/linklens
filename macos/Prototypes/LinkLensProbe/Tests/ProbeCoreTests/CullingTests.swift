import Foundation
import Testing
@testable import ProbeCore

@Suite("Bursts")
struct BurstGrouperTests {
    let thresholds = Thresholds()

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
    let thresholds = Thresholds()

    @Test func sharpPhotoIsKept() {
        let (photos, _) = Classifier.classify([makeAnalysis("a")], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .keep)
        #expect(photos[0].reasons.isEmpty)
    }

    @Test func blurLevels() {
        let (photos, _) = Classifier.classify(
            [makeAnalysis("very", sharpness: 10), makeAnalysis("slightly", sharpness: 60)],
            bursts: [], thresholds: thresholds
        )
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.first?.code == .blurry)
        #expect(photos[1].verdict == .review)
        #expect(photos[1].reasons.first?.code == .slightlyBlurry)
    }

    @Test func subjectCutByTheRightEdge() {
        // Like DSC04317: the car's box stops 1.5 % before the right edge.
        let analysis = makeAnalysis("cut", subject: CGRect(x: 0.48, y: 0.34, width: 0.505, height: 0.22))
        let (photos, _) = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.first?.message == "Sujet coupé par le bord droit")
    }

    @Test func subjectTooCloseToTheEdge() {
        let analysis = makeAnalysis("tight", subject: CGRect(x: 0.04, y: 0.4, width: 0.5, height: 0.2))
        let (photos, _) = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .review)
        #expect(photos[0].reasons.first?.code == .subjectTight)
        #expect(photos[0].reasons.first?.message == "Sujet collé au bord gauche (marge 4,0\u{a0}%)")
    }

    @Test func frameFillingSubjectIsNotCut() {
        // A close-up fills the frame: touching the borders is expected.
        let analysis = makeAnalysis("closeup", subject: CGRect(x: 0, y: 0, width: 0.95, height: 1))
        #expect(Classifier.closestEdge(of: analysis.vision.subjectBox!, thresholds) == nil)
        let (photos, _) = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .keep)
    }

    @Test func noSubjectMeansNoFramingCheck() {
        let (photos, _) = Classifier.classify([makeAnalysis("none", subject: nil)], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .keep)
    }

    @Test func mostSevereReasonComesFirst() {
        let analysis = makeAnalysis("a", aesthetics: -0.8, highlights: 0.5)
        let (photos, _) = Classifier.classify([analysis], bursts: [], thresholds: thresholds)
        #expect(photos[0].verdict == .reject)
        #expect(photos[0].reasons.map(\.code) == [.overexposed, .lowAesthetics])
    }

    @Test func eyesClosedIsOnlyReview() {
        let (photos, _) = Classifier.classify(
            [makeAnalysis("a", faces: [face(eyesClosed: true), face(eyesClosed: nil)])],
            bursts: [], thresholds: thresholds
        )
        #expect(photos[0].verdict == .review)
        #expect(photos[0].reasons.first?.message == "Yeux fermés (1 visage)")
    }

    @Test func exactDuplicateKeepsTheFirst() {
        let (photos, _) = Classifier.classify(
            [makeAnalysis("a", sha256: "same"), makeAnalysis("b", sha256: "same")],
            bursts: [], thresholds: thresholds
        )
        #expect(photos[0].verdict == .keep)
        #expect(photos[1].verdict == .reject)
        #expect(photos[1].reasons.first?.code == .exactDuplicate)
    }

    @Test func burstBestRunnerUpAndLoser() {
        let analyses = [
            makeAnalysis("best", sharpness: 900),
            makeAnalysis("almost", sharpness: 850),
            makeAnalysis("worse", sharpness: 150, aesthetics: -0.2),
        ]
        let (photos, bursts) = Classifier.classify(analyses, bursts: [[0, 1, 2]], thresholds: thresholds)
        #expect(bursts.count == 1)
        #expect(bursts[0].best == "best")
        #expect(photos[0].isBestOfBurst && photos[0].verdict == .keep)
        #expect(photos[1].verdict == .review && photos[1].reasons.first?.code == .burstRunnerUp)
        #expect(photos[2].verdict == .reject && photos[2].reasons.first?.code == .burstLoser)
        #expect(photos.allSatisfy { $0.burstId == 1 })
    }

    @Test func eyesOpenWinsInABurst() {
        let analyses = [
            makeAnalysis("closed", faces: [face(quality: 0.5, eyesClosed: true)]),
            makeAnalysis("open", faces: [face(quality: 0.5, eyesClosed: false)]),
        ]
        let (photos, _) = Classifier.classify(analyses, bursts: [[0, 1]], thresholds: thresholds)
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
}

@Suite("Thresholds file")
struct ThresholdsTests {
    func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "thresholds-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func partialOverride() throws {
        let url = try write(#"{ "blurReject": 12.5 }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try Thresholds.load(from: url)
        #expect(loaded.blurReject == 12.5)
        #expect(loaded.blurReview == Thresholds().blurReview)
    }

    @Test func unknownKeyIsRejected() throws {
        let url = try write(#"{ "blurRejekt": 12 }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ProbeError.self) { try Thresholds.load(from: url) }
    }
}

@Suite("Files")
struct FileSafetyTests {
    @Test func outputInsideSourceIsDetected() {
        let source = URL(fileURLWithPath: "/Users/me/photos")
        #expect(PhotoScanner.isInside(URL(fileURLWithPath: "/Users/me/photos/out"), source))
        #expect(PhotoScanner.isInside(source, source))
        #expect(!PhotoScanner.isInside(URL(fileURLWithPath: "/Users/me/photos-out"), source))
    }

    @Test func contactSheetEscapesHTML() {
        #expect(ContactSheet.escape("<a & \"b\">") == "&lt;a &amp; &quot;b&quot;&gt;")
    }
}

@Suite("SwiftData")
struct VolumeSmokeTests {
    @Test func smallVolumeRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "volume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await VolumeTest.run(
            count: 300, galleryCount: 3, batchSize: 50,
            storeURL: folder.appending(path: "test.store")
        )
        #expect(result.photoCount == 300)
        #expect(result.queryResultCount == 50)
    }
}
