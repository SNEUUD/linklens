import CoreGraphics
import Foundation
import Testing
@testable import LinkLens

/// Batch 3: what the inspector says, in plain words (reasons, gauges, infos, verdict caption).
struct InspectorTextTests {
    private let french = Locale(identifier: "fr_FR")

    // MARK: - « Pourquoi ce choix »

    @Test func bestOfBurstSaysHowManyPhotosAndWhy() {
        let lines = ReasonExplanations.explanations(
            for: [CullingReason(kind: .bestOfBurst, verdict: .keep)],
            burst: BurstContext(count: 7, span: 0, isSharpest: true),
            hasSubject: true, locale: french
        )
        // As in the mockup: the burst line, then a positive line since nothing is wrong.
        #expect(lines.map(\.title) == ["Meilleure photo de la rafale", "Sujet net, cadrage complet"])
        #expect(lines[0].detail == "7 photos prises dans la même seconde. Celle-ci a le sujet le plus net.")
        #expect(lines[0].tone == .gold)
        #expect(lines[0].symbolName == "star.fill")
        #expect(lines[1].detail == "Le sujet est entier et loin des bords.")
        #expect(lines[1].tone == .verdict(.keep))
    }

    @Test func burstDetailFollowsItsDurationAndTheWinningCriterion() {
        let longer = ReasonExplanations.bestOfBurstDetail(BurstContext(count: 5, span: 1.2, isSharpest: false), hasSubject: true)
        #expect(longer == "5 photos prises en 2 secondes. Celle-ci a le meilleur ensemble netteté et composition.")
        let undated = ReasonExplanations.bestOfBurstDetail(BurstContext(count: 3, span: nil, isSharpest: true), hasSubject: false)
        #expect(undated == "Rafale de 3 photos. Celle-ci est la plus nette.")
    }

    @MainActor
    @Test func burstContextComesFromTheMembers() throws {
        let container = try makeInMemoryContainer()
        let start = Date(timeIntervalSince1970: 1_789_908_057)
        let photos = (0..<3).map { index in
            let photo = Photo(draft: PhotoDraft(
                file: PhotoFile(url: URL(filePath: "/tmp/\(index).ARW"), relativePath: "\(index).ARW", fileSize: 1),
                metadata: PhotoMetadata(captureDate: start + Double(index) * 0.4, pixelWidth: 1, pixelHeight: 1),
                importedAt: start
            ))
            container.mainContext.insert(photo)
            photo.sharpness = [90, 140, 120][index]
            return photo
        }
        let context = BurstContext(photo: photos[1], members: photos)
        #expect(context.count == 3)
        #expect(abs((context.span ?? -1) - 0.8) < 0.001)
        #expect(context.isSharpest)
        #expect(BurstContext(photo: photos[0], members: photos).isSharpest == false)
    }

    @Test func defectsAreExplainedMostSevereFirstWithoutAPositiveLine() {
        let reasons = [
            CullingReason(kind: .blurry, verdict: .reject, value: 34, threshold: 45, onSubject: true),
            CullingReason(kind: .subjectCut, verdict: .reject, value: 0.01, side: .right),
        ]
        let lines = ReasonExplanations.explanations(for: reasons, hasSubject: true, locale: french)
        #expect(lines.map(\.title) == ["Floue", "Sujet coupé"])
        #expect(lines[0].detail == "Le sujet n'est pas net : il a bougé, ou la mise au point est ailleurs.")
        #expect(lines[1].detail == "Le bord droit de la photo coupe le sujet.")
        #expect(lines.allSatisfy { $0.tone == .verdict(.reject) })
    }

    @Test func everyReasonHasPlainWords() {
        let cases: [(CullingReason, String, String)] = [
            (CullingReason(kind: .slightlyBlurry, verdict: .review, value: 50, threshold: 65, onSubject: false),
             "Légèrement floue", "La photo manque un peu de netteté. Regardez-la en grand avant de décider."),
            (CullingReason(kind: .subjectTight, verdict: .review, value: 0.04, side: .top),
             "Sujet collé au bord", "Le sujet touche presque le haut : peu de place pour recadrer."),
            (CullingReason(kind: .overexposed, verdict: .reject, value: 0.22),
             "Très surexposée", "22 % de la photo est blanche, sans aucun détail."),
            (CullingReason(kind: .slightlyOverexposed, verdict: .review, value: 0.06),
             "Zones claires brûlées", "6 % de la photo est blanche, sans détail : souvent le ciel ou un reflet."),
            (CullingReason(kind: .underexposed, verdict: .review, value: 0.35),
             "Sous-exposée", "35 % de la photo est noire, sans détail."),
            (CullingReason(kind: .eyesClosed, verdict: .review, count: 1),
             "Yeux fermés", "Une personne a les yeux fermés."),
            (CullingReason(kind: .eyesClosed, verdict: .review, count: 3),
             "Yeux fermés", "3 personnes ont les yeux fermés."),
            (CullingReason(kind: .burstRunnerUp, verdict: .review, bestPhoto: "DSC04311.ARW"),
             "Presque aussi bonne que la meilleure", "DSC04311 est un peu meilleure. Gardez celle-ci si vous la préférez."),
            (CullingReason(kind: .burstLoser, verdict: .reject, bestPhoto: "Jour 2/DSC04311.ARW"),
             "Moins réussie que d'autres de la rafale", "La meilleure photo de cette rafale est Jour 2/DSC04311."),
            (CullingReason(kind: .lowAesthetics, verdict: .review, value: -0.5),
             "Photo peu attrayante", "Lumière, cadrage ou sujet : l'IA la trouve moins réussie. À vous de juger."),
            (CullingReason(kind: .utility, verdict: .review),
             "Photo utilitaire", "Elle ressemble à un document, un reçu ou une capture d'écran."),
            (CullingReason(kind: .analysisFailed, verdict: .review),
             "Analyse impossible", "Le fichier n'a pas pu être lu. Vérifiez-la vous-même."),
            (CullingReason(kind: .unknown, verdict: .unknown),
             "Raison inconnue", "Elle vient d'une version plus récente de LinkLens."),
        ]
        for (reason, title, detail) in cases {
            let line = ReasonExplanations.explanation(for: reason, locale: french)
            #expect(line.title == title)
            #expect(normalizedSpaces(line.detail) == detail)
            // No raw measurement (sharpness 50, threshold 65) in the sentence a beginner reads.
            #expect(!line.detail.contains("65"))
        }
    }

    @Test func noIssueBecomesThePositiveLine() {
        let withSubject = ReasonExplanations.explanations(for: [CullingReason(kind: .noIssue, verdict: .keep)], hasSubject: true)
        #expect(withSubject.map(\.title) == ["Sujet net, cadrage complet"])
        let withoutSubject = ReasonExplanations.explanations(for: [CullingReason(kind: .noIssue, verdict: .keep)], hasSubject: false)
        #expect(withoutSubject.map(\.title) == ["Nette et bien exposée"])
        // A photo not analysed yet, or kept for an unknown reason, gets no praise.
        #expect(ReasonExplanations.explanations(for: [], hasSubject: true).isEmpty)
        let unknown = ReasonExplanations.explanations(for: [CullingReason(kind: .unknown, verdict: .keep)], hasSubject: true)
        #expect(unknown.map(\.title) == ["Raison inconnue"])
    }

    // MARK: - Gauges

    @Test func sharpnessLevelsFollowTheCullingThresholds() {
        let thresholds = CullingThresholds()
        let blurry = InspectorGauges.sharpness(thresholds.blurReject - 1, onSubject: true)
        let slightly = InspectorGauges.sharpness(thresholds.blurReject, onSubject: true)
        let sharp = InspectorGauges.sharpness(thresholds.blurReview, onSubject: true)
        let verySharp = InspectorGauges.sharpness(85.9, onSubject: true, locale: french)
        #expect([blurry, slightly, sharp, verySharp].map(\.label) == ["Floue", "Légèrement floue", "Nette", "Très nette"])
        #expect([blurry, slightly, sharp, verySharp].map(\.tone) == [.reject, .review, .keep, .keep])
        // DSC04311: about 90 % of the bar (the mockup drew 88 %).
        #expect(abs(verySharp.fraction - 0.9) < 0.02)
        #expect(blurry.fraction < slightly.fraction && slightly.fraction < sharp.fraction)
        // The numbers stay in the tooltip.
        #expect(verySharp.detail == "Netteté mesurée sur le sujet : 86 (floue sous 42, légèrement floue sous 50)")
        #expect(InspectorGauges.sharpness(5, onSubject: false).fraction > 0, "an empty bar would look broken")
        #expect(InspectorGauges.sharpness(900, onSubject: false).fraction == 1)
    }

    @Test func exposureLevelsFollowTheCullingThresholds() {
        let correct = InspectorGauges.exposure(highlights: 0, shadows: 0.0002, locale: french)
        let burnt = InspectorGauges.exposure(highlights: 0.06, shadows: 0)
        let veryBurnt = InspectorGauges.exposure(highlights: 0.25, shadows: 0)
        let dark = InspectorGauges.exposure(highlights: 0, shadows: 0.4)
        #expect([correct, burnt, veryBurnt, dark].map(\.label) == ["Correcte", "Zones claires brûlées", "Très surexposée", "Sous-exposée"])
        #expect([correct, burnt, veryBurnt, dark].map(\.tone) == [.keep, .review, .reject, .review])
        #expect(correct.fraction > 0.99)
        #expect(burnt.fraction < 0.5 && veryBurnt.fraction < burnt.fraction)
        #expect(normalizedSpaces(correct.detail) == "Blanc sans détail : 0 % de la photo · noir sans détail : 0 %")
    }

    // MARK: - « Infos »

    @Test func cameraNamesAreTidied() {
        #expect(InspectorInfo.camera(make: "SONY", model: "ILCE-6000") == "Sony ILCE-6000")
        #expect(InspectorInfo.camera(make: "Canon", model: "Canon EOS R6") == "Canon EOS R6")
        #expect(InspectorInfo.camera(make: "NIKON CORPORATION", model: "NIKON Z 6") == "NIKON Z 6")
        #expect(InspectorInfo.camera(make: "Apple", model: "iPhone 15 Pro") == "Apple iPhone 15 Pro")
        #expect(InspectorInfo.camera(make: "DJI", model: nil) == "DJI")
        #expect(InspectorInfo.camera(make: nil, model: nil) == nil)
    }

    @Test func settingsReadLikeOnACamera() {
        let a6000 = CaptureInfo(exposureTime: 0.00625, fNumber: 10, iso: 100, focalLength: 173)
        #expect(InspectorInfo.settings(a6000, locale: french) == "1/160 s · f/10 · ISO 100 · 173 mm")
        let phone = CaptureInfo(exposureTime: 1.5, fNumber: 1.8, iso: nil, focalLength: 6.9)
        #expect(InspectorInfo.settings(phone, locale: french) == "1,5 s · f/1,8 · 6,9 mm")
        #expect(InspectorInfo.shutterSpeed(1.0 / 3200) == "1/3200 s")
        #expect(InspectorInfo.settings(CaptureInfo()) == nil)
    }

    @Test func fileKindAndSize() {
        #expect(normalizedSpaces(InspectorInfo.file(relativePath: "DSC04311.ARW", size: 24_903_680, locale: french)) == "RAW · 24,9 Mo")
        #expect(InspectorInfo.file(relativePath: "a/IMG_1.jpeg", size: 0) == "JPEG")
        #expect(InspectorInfo.file(relativePath: "C0001.MP4", size: 0) == "Vidéo MP4")
        #expect(InspectorInfo.file(relativePath: "IMG_1.HEIC", size: 0) == "HEIC")
        #expect(normalizedSpaces(InspectorInfo.duration(83.4, locale: french)) == "1 min et 23 s")
    }

    @Test func headerLine() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 14, minute: 41, second: 6)))
        #expect(normalizedSpaces(InspectorInfo.dateLine(date: date, burstNumber: 4, locale: french)) == "20 sept. 2026 à 14:41:06 · rafale 4")
        #expect(InspectorInfo.dateLine(date: nil, burstNumber: nil) == "Date inconnue")
    }

    // MARK: - Subject and verdict

    @Test func subjectBoxIsDescribedForVoiceOver() {
        // DSC04311: the car across the middle of the photo.
        let box = CGRect(x: 0.1029, y: 0.3435, width: 0.6593, height: 0.1951)
        #expect(normalizedSpaces(InspectorSubject.accessibilityDescription(of: box, locale: french))
            == "Sujet détecté au centre, à mi-hauteur. Il occupe 13 % de la photo.")
        let corner = CGRect(x: 0.7, y: 0.75, width: 0.2, height: 0.2)
        #expect(InspectorSubject.accessibilityDescription(of: corner, locale: french).hasPrefix("Sujet détecté à droite, en bas."))
    }

    @MainActor
    @Test func captionSaysWhoChose() throws {
        let container = try makeInMemoryContainer()
        let photo = Photo(draft: PhotoDraft(
            file: PhotoFile(url: URL(filePath: "/tmp/a.ARW"), relativePath: "a.ARW", fileSize: 1),
            metadata: .unknown, importedAt: .now
        ))
        container.mainContext.insert(photo)
        #expect(VerdictCaption(photo: photo) == .notSorted)

        photo.cullingVerdictRaw = "keep"
        let proposed = VerdictCaption(photo: photo)
        #expect(proposed == .proposedByAI)
        #expect(proposed.text == "Proposé par l'IA. Changez avec")
        #expect(proposed.showsKeys && !proposed.canFollowAI)
        #expect(proposed.reasonsTitle == "Pourquoi ce choix")

        photo.userVerdictRaw = "review"
        let chosen = VerdictCaption(photo: photo)
        #expect(chosen.text == "Votre choix · l'IA proposait Garder")
        #expect(chosen.canFollowAI && !chosen.showsKeys)
        #expect(chosen.reasonsTitle == "Pourquoi l'IA proposait « Garder »")

        photo.userVerdictRaw = "keep"
        #expect(VerdictCaption(photo: photo).text == "Votre choix, le même que l'IA")
        #expect(VerdictCaption(photo: photo).reasonsTitle == "Pourquoi ce choix")
    }
}

/// French formatting puts narrow or regular no-break spaces before « % », « Mo » and « s ».
func normalizedSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}
