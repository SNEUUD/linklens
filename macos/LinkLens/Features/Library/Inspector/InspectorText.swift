import CoreGraphics
import Foundation

// What the inspector says about a photo, in plain words, kept apart from the views so the tests can
// check every sentence. The views only lay these values out.

// MARK: - « Pourquoi ce choix »

/// One line of « Pourquoi ce choix »: an icon, a short title and a sentence a beginner understands.
struct ReasonExplanation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case verdict(CullingVerdict)
        /// The star of the best photo of a burst.
        case gold
    }

    var symbolName: String
    var tone: Tone
    var title: String
    var detail: String
}

/// What the inspector knows about the burst of the photo, to explain « Meilleure photo de la rafale ».
struct BurstContext: Equatable, Sendable {
    /// Photos in the burst (2 or more).
    var count: Int
    /// Seconds between its first and last photo; nil when a date is missing.
    var span: TimeInterval?
    /// True when this photo has the best sharpness of the burst.
    var isSharpest: Bool

    /// From the photos of one burst (`photo` among them).
    init(photo: Photo, members: [Photo]) {
        count = members.count
        let dates = members.compactMap(\.captureDate)
        span = dates.count == members.count ? dates.max().map { last in last.timeIntervalSince(dates.min()!) } : nil
        let best = members.compactMap(\.sharpness).max()
        isSharpest = photo.sharpness != nil && photo.sharpness == best
    }

    init(count: Int, span: TimeInterval?, isSharpest: Bool) {
        self.count = count
        self.span = span
        self.isSharpest = isSharpest
    }
}

enum ReasonExplanations {
    /// The lines of « Pourquoi ce choix », most severe first (the order of the stored reasons).
    /// A photo without any problem gets one positive line instead of « Aucun défaut détecté ».
    static func explanations(
        for reasons: [CullingReason],
        burst: BurstContext? = nil,
        hasSubject: Bool,
        locale: Locale = .current
    ) -> [ReasonExplanation] {
        var lines = reasons
            .filter { $0.kind != .noIssue }
            .map { explanation(for: $0, burst: burst, hasSubject: hasSubject, locale: locale) }
        // Nothing to fix: says what is good, as in the mockup (« Sujet net, cadrage complet »).
        let isFlawless = !reasons.isEmpty && reasons.allSatisfy { $0.verdict == .keep && $0.kind != .unknown }
        if isFlawless {
            lines.append(positive(hasSubject: hasSubject))
        }
        return lines
    }

    static func explanation(
        for reason: CullingReason,
        burst: BurstContext? = nil,
        hasSubject: Bool = true,
        locale: Locale = .current
    ) -> ReasonExplanation {
        let tone = ReasonExplanation.Tone.verdict(reason.verdict)
        let onSubject = reason.onSubject ?? hasSubject
        let best = reason.bestPhoto.map { ($0 as NSString).deletingPathExtension } ?? "—"
        let share = (reason.value ?? 0).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        switch reason.kind {
        case .bestOfBurst:
            return ReasonExplanation(
                symbolName: "star.fill", tone: .gold,
                title: String(localized: "Meilleure photo de la rafale"),
                detail: bestOfBurstDetail(burst, hasSubject: hasSubject)
            )
        case .burstRunnerUp:
            return ReasonExplanation(
                symbolName: "square.stack", tone: tone,
                title: String(localized: "Presque aussi bonne que la meilleure"),
                detail: String(localized: "\(best) est un peu meilleure. Gardez celle-ci si vous la préférez.")
            )
        case .burstLoser:
            return ReasonExplanation(
                symbolName: "square.stack", tone: tone,
                title: String(localized: "Moins réussie que d'autres de la rafale"),
                detail: String(localized: "La meilleure photo de cette rafale est \(best).")
            )
        case .blurry:
            return ReasonExplanation(
                symbolName: "scope", tone: tone,
                title: String(localized: "Floue"),
                detail: onSubject
                    ? String(localized: "Le sujet n'est pas net : il a bougé, ou la mise au point est ailleurs.")
                    : String(localized: "La photo n'est pas nette : l'appareil a bougé, ou la mise au point est ratée.")
            )
        case .slightlyBlurry:
            return ReasonExplanation(
                symbolName: "scope", tone: tone,
                title: String(localized: "Légèrement floue"),
                detail: onSubject
                    ? String(localized: "Le sujet manque un peu de netteté. Regardez-la en grand avant de décider.")
                    : String(localized: "La photo manque un peu de netteté. Regardez-la en grand avant de décider.")
            )
        case .subjectCut:
            return ReasonExplanation(
                symbolName: "crop", tone: tone,
                title: String(localized: "Sujet coupé"),
                detail: cutDetail(reason.side)
            )
        case .subjectTight:
            return ReasonExplanation(
                symbolName: "crop", tone: tone,
                title: String(localized: "Sujet collé au bord"),
                detail: tightDetail(reason.side)
            )
        case .overexposed:
            return ReasonExplanation(
                symbolName: "sun.max", tone: tone,
                title: String(localized: "Très surexposée"),
                detail: String(localized: "\(share) de la photo est blanche, sans aucun détail.")
            )
        case .slightlyOverexposed:
            return ReasonExplanation(
                symbolName: "sun.max", tone: tone,
                title: String(localized: "Zones claires brûlées"),
                detail: String(localized: "\(share) de la photo est blanche, sans détail : souvent le ciel ou un reflet.")
            )
        case .underexposed:
            return ReasonExplanation(
                symbolName: "moon", tone: tone,
                title: String(localized: "Sous-exposée"),
                detail: String(localized: "\(share) de la photo est noire, sans détail.")
            )
        case .eyesClosed:
            let faces = reason.count ?? 1
            return ReasonExplanation(
                symbolName: "eye.slash", tone: tone,
                title: String(localized: "Yeux fermés"),
                detail: faces == 1
                    ? String(localized: "Une personne a les yeux fermés.")
                    : String(localized: "\(faces) personnes ont les yeux fermés.")
            )
        case .lowAesthetics:
            return ReasonExplanation(
                symbolName: "sparkles", tone: tone,
                title: String(localized: "Photo peu attrayante"),
                detail: String(localized: "Lumière, cadrage ou sujet : l'IA la trouve moins réussie. À vous de juger.")
            )
        case .utility:
            return ReasonExplanation(
                symbolName: "doc.text", tone: tone,
                title: String(localized: "Photo utilitaire"),
                detail: String(localized: "Elle ressemble à un document, un reçu ou une capture d'écran.")
            )
        case .noIssue:
            return positive(hasSubject: hasSubject)
        case .analysisFailed:
            return ReasonExplanation(
                symbolName: "exclamationmark.triangle", tone: tone,
                title: String(localized: "Analyse impossible"),
                detail: String(localized: "Le fichier n'a pas pu être lu. Vérifiez-la vous-même.")
            )
        case .unknown:
            return ReasonExplanation(
                symbolName: "questionmark.circle", tone: tone,
                title: String(localized: "Raison inconnue"),
                detail: String(localized: "Elle vient d'une version plus récente de LinkLens.")
            )
        }
    }

    private static func cutDetail(_ side: FrameSide?) -> String {
        switch side {
        case .left: String(localized: "Le bord gauche de la photo coupe le sujet.")
        case .right: String(localized: "Le bord droit de la photo coupe le sujet.")
        case .top: String(localized: "Le haut de la photo coupe le sujet.")
        case .bottom: String(localized: "Le bas de la photo coupe le sujet.")
        case nil: String(localized: "Un bord de la photo coupe le sujet.")
        }
    }

    private static func tightDetail(_ side: FrameSide?) -> String {
        switch side {
        case .left: String(localized: "Le sujet touche presque le bord gauche : peu de place pour recadrer.")
        case .right: String(localized: "Le sujet touche presque le bord droit : peu de place pour recadrer.")
        case .top: String(localized: "Le sujet touche presque le haut : peu de place pour recadrer.")
        case .bottom: String(localized: "Le sujet touche presque le bas : peu de place pour recadrer.")
        case nil: String(localized: "Le sujet touche presque un bord : peu de place pour recadrer.")
        }
    }

    /// « 7 photos prises dans la même seconde. Celle-ci a le sujet le plus net. »
    static func bestOfBurstDetail(_ burst: BurstContext?, hasSubject: Bool) -> String {
        guard let burst else {
            return String(localized: "Elle représente sa rafale dans la grille.")
        }
        let count = burst.count
        let taken: String
        if let span = burst.span, span < 1 {
            taken = String(localized: "\(count) photos prises dans la même seconde.")
        } else if let span = burst.span {
            // Rounded up: 1,2 s is « en 2 secondes », never « en 1 secondes ».
            let seconds = max(2, Int(span.rounded(.up)))
            taken = String(localized: "\(count) photos prises en \(seconds) secondes.")
        } else {
            taken = String(localized: "Rafale de \(count) photos.")
        }
        let why: String
        if burst.isSharpest {
            why = hasSubject ? String(localized: "Celle-ci a le sujet le plus net.") : String(localized: "Celle-ci est la plus nette.")
        } else {
            why = String(localized: "Celle-ci a le meilleur ensemble netteté et composition.")
        }
        return taken + " " + why
    }

    /// The line of a photo with nothing to fix.
    static func positive(hasSubject: Bool) -> ReasonExplanation {
        hasSubject
            ? ReasonExplanation(
                symbolName: "checkmark", tone: .verdict(.keep),
                title: String(localized: "Sujet net, cadrage complet"),
                detail: String(localized: "Le sujet est entier et loin des bords.")
            )
            : ReasonExplanation(
                symbolName: "checkmark", tone: .verdict(.keep),
                title: String(localized: "Nette et bien exposée"),
                detail: String(localized: "L'analyse n'a trouvé aucun défaut.")
            )
    }
}

// MARK: - Gauges

/// A gauge of the inspector: a word (« Très nette »), how full the bar is, its colour and, in the
/// tooltip only, the measured numbers (they mean little to a beginner).
struct GaugeReading: Equatable, Sendable {
    var label: String
    /// 0…1.
    var fraction: Double
    var tone: CullingVerdict
    /// Tooltip: the measured values and the thresholds.
    var detail: String
}

enum InspectorGauges {
    /// Above this sharpness, a photo is « Très nette ». Only a word for the inspector: the verdicts use
    /// `CullingThresholds` alone. (The first real session went from 30 to 171.)
    static let verySharp = 120.0
    /// The bar is on a logarithmic scale between these two values (sharpness grows very fast).
    static let sharpnessScale = 20.0...200.0

    static func sharpness(
        _ value: Double,
        onSubject: Bool,
        thresholds: CullingThresholds = CullingThresholds(),
        locale: Locale = .current
    ) -> GaugeReading {
        let label: String
        let tone: CullingVerdict
        if value < thresholds.blurReject {
            (label, tone) = (String(localized: "Floue"), .reject)
        } else if value < thresholds.blurReview {
            (label, tone) = (String(localized: "Légèrement floue"), .review)
        } else if value < verySharp {
            (label, tone) = (String(localized: "Nette"), .keep)
        } else {
            (label, tone) = (String(localized: "Très nette"), .keep)
        }
        let low = log(sharpnessScale.lowerBound), high = log(sharpnessScale.upperBound)
        let fraction = (log(max(value, 1)) - low) / (high - low)
        let measured = number(value, locale), reject = number(thresholds.blurReject, locale)
        let review = number(thresholds.blurReview, locale)
        let place = onSubject ? String(localized: "sur le sujet") : String(localized: "sur toute la photo")
        return GaugeReading(
            label: label, fraction: clamped(fraction), tone: tone,
            detail: String(localized: "Netteté mesurée \(place) : \(measured) (floue sous \(reject), légèrement floue sous \(review))")
        )
    }

    /// Exposure from the share of burnt highlights and blocked shadows. A full bar: nothing lost.
    static func exposure(
        highlights: Double,
        shadows: Double,
        thresholds: CullingThresholds = CullingThresholds(),
        locale: Locale = .current
    ) -> GaugeReading {
        let label: String
        let tone: CullingVerdict
        if highlights > thresholds.highlightReject {
            (label, tone) = (String(localized: "Très surexposée"), .reject)
        } else if highlights > thresholds.highlightReview {
            (label, tone) = (String(localized: "Zones claires brûlées"), .review)
        } else if shadows > thresholds.shadowReview {
            (label, tone) = (String(localized: "Sous-exposée"), .review)
        } else {
            (label, tone) = (String(localized: "Correcte"), .keep)
        }
        // How much of the photo is lost, compared with what makes it « À revoir » (half the bar) and worse.
        let lost = max(highlights / thresholds.highlightReview, shadows / thresholds.shadowReview) / 2
        let white = percent(highlights, locale), black = percent(shadows, locale)
        return GaugeReading(
            label: label, fraction: clamped(1 - lost, minimum: 0.06), tone: tone,
            detail: String(localized: "Blanc sans détail : \(white) de la photo · noir sans détail : \(black)")
        )
    }

    private static func clamped(_ value: Double, minimum: Double = 0.04) -> Double {
        min(1, max(minimum, value))
    }

    private static func number(_ value: Double, _ locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    private static func percent(_ share: Double, _ locale: Locale) -> String {
        share.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    }
}

// MARK: - « Infos »

enum InspectorInfo {
    /// « Sony ILCE-6000 », « Canon EOS R6 » (the make is not repeated), « Nikon Z 6 ».
    static func camera(make: String?, model: String?) -> String? {
        let brand = make.map(brandName)
        guard let model else { return brand }
        guard let brand, !model.lowercased().hasPrefix(brand.lowercased()) else { return model }
        return "\(brand) \(model)"
    }

    /// « SONY » → « Sony », « NIKON CORPORATION » → « Nikon », « OLYMPUS IMAGING CORP. » → « Olympus ».
    static func brandName(_ make: String) -> String {
        let first = make.split(separator: " ").first.map(String.init) ?? make
        // Only shouting names get new capitals: « Canon », « Apple » or « DJI » stay as they are.
        return first == first.uppercased() && first.count > 3 ? first.capitalized : first
    }

    /// « 1/160 s · f/5,6 · ISO 100 · 210 mm », nil when the photo has no settings.
    static func settings(_ capture: CaptureInfo, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let time = capture.exposureTime { parts.append(shutterSpeed(time, locale: locale)) }
        if let aperture = capture.fNumber {
            parts.append("f/" + aperture.formatted(.number.precision(.fractionLength(0...1)).locale(locale)))
        }
        if let iso = capture.iso { parts.append("ISO \(iso)") }
        if let focal = capture.focalLength {
            parts.append(focal.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + " mm")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « 1/160 s » under a second (as written on cameras), « 2 s » or « 1,5 s » above.
    static func shutterSpeed(_ seconds: Double, locale: Locale = .current) -> String {
        if seconds >= 0.3 {
            return seconds.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + " s"
        }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    /// « RAW · 24,9 Mo », « JPEG · 3,2 Mo », « Vidéo MP4 · 120 Mo ».
    static func file(relativePath: String, size: Int64, locale: Locale = .current) -> String {
        let fileExtension = (relativePath as NSString).pathExtension.lowercased()
        let kind: String
        if rawExtensions.contains(fileExtension) {
            kind = "RAW"
        } else if fileExtension == "jpg" || fileExtension == "jpeg" {
            kind = "JPEG"
        } else if fileExtension == "heif" {
            kind = "HEIC"
        } else if MediaKind.videoExtensions.contains(fileExtension) {
            kind = String(localized: "Vidéo \(fileExtension.uppercased())")
        } else {
            kind = fileExtension.uppercased()
        }
        guard size > 0 else { return kind }
        return kind + " · " + size.formatted(.byteCount(style: .file).locale(locale))
    }

    static let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "dng", "pef", "srw", "x3f"]

    /// « 1 min et 23 s », « 12 s ».
    static func duration(_ seconds: Double, locale: Locale = .current) -> String {
        Duration.seconds(seconds.rounded()).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(locale)
        )
    }

    /// « 20 sept. 2026 à 14:41:06 · rafale 4 ».
    static func dateLine(date: Date?, burstNumber: Int?, locale: Locale = .current) -> String {
        var parts: [String] = []
        if let date {
            parts.append(date.formatted(
                .dateTime.day().month(.abbreviated).year().hour().minute().second().locale(locale)
            ))
        }
        if let burstNumber { parts.append(String(localized: "rafale \(burstNumber)")) }
        return parts.isEmpty ? String(localized: "Date inconnue") : parts.joined(separator: " · ")
    }
}

// MARK: - Subject and verdict

enum InspectorSubject {
    /// VoiceOver: « Sujet détecté au centre, à mi-hauteur. Il occupe 13 % de la photo. »
    static func accessibilityDescription(of box: CGRect, locale: Locale = .current) -> String {
        let horizontal = box.midX < 0.4 ? String(localized: "à gauche") : box.midX > 0.6 ? String(localized: "à droite") : String(localized: "au centre")
        let vertical = box.midY < 0.4 ? String(localized: "en haut") : box.midY > 0.6 ? String(localized: "en bas") : String(localized: "à mi-hauteur")
        let area = Double(box.width * box.height).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return String(localized: "Sujet détecté \(horizontal), \(vertical). Il occupe \(area) de la photo.")
    }
}

/// The line under the Garder / À revoir / Rejeter buttons.
enum VerdictCaption: Equatable {
    /// « Proposé par l'IA. Changez avec P U X ».
    case proposedByAI
    /// « Votre choix · l'IA proposait Rejeter », with « Revenir à la proposition de l'IA ».
    case chosenByUser(CullingVerdict, aiProposal: CullingVerdict?)
    /// Not sorted yet (or a video): « Pas encore triée. Triez avec P U X ».
    case notSorted
    /// « Les vidéos ne sont pas triées par l'IA. Triez avec P U X ».
    case video

    init(photo: Photo) {
        if photo.isVerdictChosenByUser {
            self = .chosenByUser(photo.userVerdict ?? .unknown, aiProposal: photo.cullingVerdict)
        } else if photo.mediaKind == .video {
            self = .video
        } else if photo.cullingVerdict != nil {
            self = .proposedByAI
        } else {
            self = .notSorted
        }
    }

    /// The words before the keys (or the whole line for a choice of the user).
    var text: String {
        switch self {
        case .proposedByAI: String(localized: "Proposé par l'IA. Changez avec")
        case .chosenByUser(let choice, let proposal?) where proposal == choice:
            String(localized: "Votre choix, le même que l'IA")
        case .chosenByUser(_, let proposal?): String(localized: "Votre choix · l'IA proposait \(proposal.label)")
        case .chosenByUser(_, nil): String(localized: "Votre choix")
        case .notSorted: String(localized: "Pas encore triée par l'IA. Triez avec")
        case .video: String(localized: "Les vidéos ne sont pas triées par l'IA. Triez avec")
        }
    }

    /// The keys shown after `text`: P U X, none after a choice of the user (the button says A).
    var showsKeys: Bool {
        if case .chosenByUser = self { return false }
        return true
    }

    /// Above the reasons, which are always the AI's: « Pourquoi l'IA proposait Garder » once the user
    /// chose something else, so they are not read as the reasons of the user's choice.
    var reasonsTitle: String {
        if case .chosenByUser(let choice, let proposal?) = self, proposal != choice {
            return String(localized: "Pourquoi l'IA proposait « \(proposal.label) »")
        }
        return String(localized: "Pourquoi ce choix")
    }

    /// « Revenir à la proposition de l'IA » makes sense only after a choice of the user.
    var canFollowAI: Bool {
        if case .chosenByUser = self { return true }
        return false
    }
}
