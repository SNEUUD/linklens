import CoreGraphics
import Foundation

// What the full-window viewer shows besides the photo, kept apart from the views so the tests can check
// it: the filmstrip, the line under the photo's name, the AI's reason in one sentence and the 100 % zoom.

// MARK: - Filmstrip

/// The thumbnails at the bottom of the viewer. In an open burst: its photos, with the photo (or burst)
/// before and after it dimmed on each side. Anywhere else: the neighbouring photos, as shown by the
/// current filter (a collapsed burst counts as one, as with ← →).
struct Filmstrip: Equatable, Sendable {
    /// The photo or burst just before `items`, drawn dimmed; nil at the start of the gallery.
    var leading: GalleryEntry?
    /// The main thumbnails, the selected photo among them.
    var items: [GalleryEntry]
    /// The photo or burst just after `items`, drawn dimmed; nil at the end.
    var trailing: GalleryEntry?
    /// The open burst whose photos are `items` (all of them, or as many as fit around the selected one);
    /// nil when `items` are neighbouring photos.
    var burstNumber: Int?

    static let empty = Filmstrip(leading: nil, items: [], trailing: nil, burstNumber: nil)

    /// Most thumbnails ever shown, even in a wide window: beyond that the strip gets hard to read.
    static let maximumItems = 9

    /// - Parameters:
    ///   - entries: what the grid shows, in order (`GalleryBrowser.entries`, so the filter applies).
    ///   - selection: the photo shown in the viewer.
    ///   - maxItems: how many main thumbnails fit in the window; the selected one stays in the middle
    ///     when there are more.
    static func make(entries: [GalleryEntry], selection: UUID?, maxItems: Int = maximumItems) -> Filmstrip {
        guard let index = entries.firstIndex(where: { $0.photoId == selection }) else { return .empty }
        let limit = max(1, min(maxItems, maximumItems))

        // The block of photos to pick from: the open burst of the selected photo, or every entry.
        var block = entries.indices
        var burstNumber: Int?
        if let burst = entries[index].burst, burst.isExpanded, !burst.isShownAlone {
            // A burst is always shown as one block (`BurstStacks`): its members are next to each other.
            func isMember(_ position: Int) -> Bool { entries[position].burst?.number == burst.number }
            var first = index, last = index
            while first > 0, isMember(first - 1) { first -= 1 }
            while last < entries.count - 1, isMember(last + 1) { last += 1 }
            block = first..<(last + 1)
            burstNumber = burst.number
        }

        // As many as fit, the selected photo in the middle, shifted at both ends of the block.
        let count = min(limit, block.count)
        let start = min(max(block.lowerBound, index - count / 2), block.upperBound - count)
        let shown = start..<(start + count)
        return Filmstrip(
            leading: shown.lowerBound > 0 ? entries[shown.lowerBound - 1] : nil,
            items: Array(entries[shown]),
            trailing: shown.upperBound < entries.count ? entries[shown.upperBound] : nil,
            burstNumber: burstNumber
        )
    }

    /// How many main thumbnails fit in `width` points, the dimmed ones and the margins included.
    static func itemsFitting(width: CGFloat, itemWidth: CGFloat, dimmedWidth: CGFloat, spacing: CGFloat = 8) -> Int {
        // Strip padding (2 × 12), two dimmed thumbnails and two separators (about 20 points each).
        let fixed = 24 + 2 * (dimmedWidth + spacing) + 2 * (20 + spacing)
        let fitting = Int(((width - fixed) / (itemWidth + spacing)).rounded(.down))
        return max(1, min(maximumItems, fitting))
    }
}

// MARK: - Context line

/// The line under the photo's name: where the photo is, so the user never gets lost while sorting.
enum ViewerContext {
    /// - « Rafale 4 ouverte · photo 5 sur 7 » (a photo of an open burst);
    /// - « Rafale 4 repliée · 7 photos » (a collapsed burst, shown by its best photo);
    /// - « À revoir · photo 3 sur 14 » under a verdict filter (« · rafale 4 » for a photo of a burst);
    /// - « Photo 12 sur 52 » otherwise, counted in the whole gallery.
    ///
    /// - Parameters:
    ///   - entries: what the grid shows (`GalleryBrowser.entries`).
    ///   - index: the shown photo's position in `entries`.
    ///   - photoCount: photos in the gallery.
    static func line(entries: [GalleryEntry], index: Int, photoCount: Int, filter: VerdictFilter) -> String {
        guard entries.indices.contains(index) else { return "" }
        let entry = entries[index]
        if filter != .all {
            var line = String(localized: "\(filter.title) · photo \(index + 1) sur \(entries.count)")
            if let burst = entry.burst {
                line += " · " + String(localized: "rafale \(burst.number)")
            }
            if entry.isOutsideFilter {
                line += " · " + String(localized: "ne correspond plus au filtre")
            }
            return line
        }
        if let burst = entry.burst {
            guard burst.isExpanded else {
                return String(localized: "Rafale \(burst.number) repliée · \(burst.count) photos")
            }
            let position = entries[..<index].filter { $0.burst?.number == burst.number }.count + 1
            return String(localized: "Rafale \(burst.number) ouverte · photo \(position) sur \(burst.count)")
        }
        return String(localized: "Photo \(entry.photoIndex + 1) sur \(photoCount)")
    }
}

// MARK: - The AI's reason in one sentence

/// The glass pill above the sorting buttons: « L'IA propose Garder : meilleure photo de la rafale, sujet
/// net et entier. », or « Votre choix · l'IA proposait Garder : … » once the user chose.
struct ViewerReasonLine: Equatable, Sendable {
    enum Icon: Equatable, Sendable {
        /// The best photo of a burst.
        case star
        case verdict(CullingVerdict)
        /// The user's own choice.
        case person
        /// Not sorted yet, or a video.
        case info
    }

    var icon: Icon
    /// Drawn in bold: « L'IA propose Garder », « Votre choix ».
    var lead: String
    /// The rest of the sentence, from its separator on: « : meilleure photo de la rafale. ».
    var rest: String
    /// « Revenir à l'IA (A) » is offered after a choice of the user.
    var canFollowAI: Bool

    /// The whole sentence, for VoiceOver.
    var text: String { lead + rest }

    /// French puts a (non-breaking) space before a colon.
    private static let colon = "\u{00A0}: "

    /// - Parameters:
    ///   - aiVerdict: the AI's proposal (`Photo.cullingVerdict`), nil when not sorted yet.
    ///   - userVerdict: the user's choice (`Photo.userVerdict`), nil when they did not choose.
    ///   - reasons: the AI's stored reasons.
    ///   - hasSubject: Vision found a subject (« sujet net » rather than « nette »).
    init(aiVerdict: CullingVerdict?, userVerdict: CullingVerdict?, reasons: [CullingReason], hasSubject: Bool, isVideo: Bool = false) {
        let summary = Self.summary(of: reasons, hasSubject: hasSubject)
        if let userVerdict {
            icon = .person
            canFollowAI = true
            lead = String(localized: "Votre choix")
            guard let aiVerdict else {
                rest = " · " + String(localized: "\(userVerdict.label), l'IA n'a rien proposé.")
                return
            }
            let because = summary.map { Self.colon + $0 } ?? "."
            rest = aiVerdict == userVerdict
                ? ", " + String(localized: "comme l'IA") + because
                : " · " + String(localized: "l'IA proposait \(aiVerdict.label)") + because
            return
        }
        canFollowAI = false
        if isVideo {
            icon = .info
            lead = String(localized: "Vidéo")
            rest = Self.colon + String(localized: "les vidéos ne sont pas triées par l'IA. Triez-la avec P, U ou X.")
        } else if let aiVerdict {
            icon = reasons.contains { $0.kind == .bestOfBurst } ? .star : .verdict(aiVerdict)
            lead = String(localized: "L'IA propose \(aiVerdict.label)")
            rest = summary.map { Self.colon + $0 } ?? "."
        } else {
            icon = .info
            lead = String(localized: "Pas encore triée par l'IA")
            rest = Self.colon + String(localized: "triez-la avec P, U ou X.")
        }
    }

    /// « meilleure photo de la rafale, sujet net et entier. »: the reasons in a few words, most severe
    /// first (their stored order), three at most. Nil when there is no reason at all.
    static func summary(of reasons: [CullingReason], hasSubject: Bool, maximum: Int = 3) -> String? {
        var phrases = reasons.filter { $0.kind != .noIssue }.map { phrase(for: $0, hasSubject: hasSubject) }
        // Nothing to fix: says what is good, like the inspector (`ReasonExplanations`).
        if !reasons.isEmpty, reasons.allSatisfy({ $0.verdict == .keep && $0.kind != .unknown }) {
            phrases.append(hasSubject ? String(localized: "sujet net et entier") : String(localized: "nette et bien exposée"))
        }
        guard !phrases.isEmpty else { return nil }
        return phrases.prefix(maximum).joined(separator: ", ") + "."
    }

    /// A few words for one reason, starting with a small letter (it follows « L'IA propose Garder : »).
    static func phrase(for reason: CullingReason, hasSubject: Bool = true) -> String {
        let onSubject = reason.onSubject ?? hasSubject
        let best = reason.bestPhoto.map { ($0 as NSString).deletingPathExtension } ?? "—"
        switch reason.kind {
        case .bestOfBurst: return String(localized: "meilleure photo de la rafale")
        case .burstRunnerUp: return String(localized: "presque aussi bonne que \(best)")
        case .burstLoser: return String(localized: "moins réussie que \(best)")
        case .blurry: return onSubject ? String(localized: "sujet flou") : String(localized: "photo floue")
        case .slightlyBlurry:
            return onSubject ? String(localized: "sujet un peu flou") : String(localized: "photo un peu floue")
        case .subjectCut:
            switch reason.side {
            case .left: return String(localized: "sujet coupé à gauche")
            case .right: return String(localized: "sujet coupé à droite")
            case .top: return String(localized: "sujet coupé en haut")
            case .bottom: return String(localized: "sujet coupé en bas")
            case nil: return String(localized: "sujet coupé")
            }
        case .subjectTight:
            switch reason.side {
            case .left: return String(localized: "sujet collé au bord gauche")
            case .right: return String(localized: "sujet collé au bord droit")
            case .top: return String(localized: "sujet collé en haut")
            case .bottom: return String(localized: "sujet collé en bas")
            case nil: return String(localized: "sujet collé à un bord")
            }
        case .overexposed: return String(localized: "très surexposée")
        case .slightlyOverexposed: return String(localized: "zones claires brûlées")
        case .underexposed: return String(localized: "sous-exposée")
        case .eyesClosed: return String(localized: "yeux fermés")
        case .lowAesthetics: return String(localized: "peu attrayante selon l'IA")
        case .utility: return String(localized: "photo utilitaire")
        case .noIssue: return String(localized: "aucun défaut détecté")
        case .analysisFailed: return String(localized: "analyse impossible, à vérifier vous-même")
        case .unknown: return String(localized: "raison inconnue")
        }
    }
}

// MARK: - 100 % zoom

/// Where the photo goes at 100 % (one pixel of the photo per pixel of the screen), to judge sharpness.
/// The subject Vision found is put in the middle; the user can then drag the photo around, never past
/// its edges.
enum ZoomFraming {
    /// Size of the photo at 100 %, in points: a Retina screen (`displayScale` 2) shows 2 pixels per point.
    static func actualSize(pixelWidth: Int, pixelHeight: Int, displayScale: CGFloat) -> CGSize {
        let scale = max(displayScale, 1)
        return CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }

    /// The point put in the middle (0…1, top-left origin): the centre of the subject, else of the photo.
    static func focus(subject: CGRect?) -> CGPoint {
        guard let subject else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: subject.midX, y: subject.midY)
    }

    /// How far the photo's centre is moved from the centre of the visible area (`viewport`).
    /// - Parameter pan: the user's drag, added to the framing on `focus`.
    /// - Returns: an offset that keeps the visible area inside the photo; along a side where the photo is
    ///   smaller than the area, the photo stays centred.
    static func offset(photoSize: CGSize, viewport: CGSize, focus: CGPoint, pan: CGSize = .zero) -> CGSize {
        func axis(_ photo: CGFloat, _ visible: CGFloat, _ focus: CGFloat, _ pan: CGFloat) -> CGFloat {
            let limit = max(0, (photo - visible) / 2)
            let wanted = (0.5 - focus) * photo + pan
            return min(limit, max(-limit, wanted))
        }
        return CGSize(
            width: axis(photoSize.width, viewport.width, focus.x, pan.width),
            height: axis(photoSize.height, viewport.height, focus.y, pan.height)
        )
    }

    /// The drag to keep once the user lets go: the part that actually moved the photo, so a drag past
    /// an edge does not have to be undone before the photo moves back.
    static func settledPan(photoSize: CGSize, viewport: CGSize, focus: CGPoint, pan: CGSize) -> CGSize {
        let moved = offset(photoSize: photoSize, viewport: viewport, focus: focus, pan: pan)
        // Measured from the framing before any limit, so the next drag moves the photo at once.
        return CGSize(
            width: moved.width - (0.5 - focus.x) * photoSize.width,
            height: moved.height - (0.5 - focus.y) * photoSize.height
        )
    }
}
