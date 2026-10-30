import Foundation
import Observation

// The review of the « À revoir » photos: one stop per burst (decided with one key) or per single photo,
// in chronological order. The logic lives here, apart from SwiftUI, so the tests can drive it.

/// One stop of the review: a whole burst, compared with its best photo and decided at once, or one photo.
struct ReviewStop: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A burst (its number in the gallery, as stored by F3).
        case burst(number: Int)
        case single
    }

    var kind: Kind
    /// Every photo shown at this stop, in chronological order: all the photos of the burst, whatever
    /// their verdict (the best one and the rejected ones help to compare), or the single photo.
    var photoIds: [UUID]
    /// Those that were « À revoir » when the review started: the photos this stop is about.
    var reviewIds: [UUID]

    var id: UUID { photoIds[0] }

    var isBurst: Bool {
        if case .burst = kind { true } else { false }
    }
}

/// Builds the stops from the gallery's photos.
enum ReviewQueue {
    /// - Parameter photos: every photo of the gallery, in display order (chronological), with the verdict
    ///   shown (the user's choice, otherwise the AI's).
    /// - Returns: one stop per burst holding at least one « À revoir » photo, at the place of its first one,
    ///   and one stop per other « À revoir » photo.
    static func stops(for photos: [BurstStacks.Input]) -> [ReviewStop] {
        // Positions of the photos of each burst, like in `BurstStacks.entries`.
        var members: [Int: [Int]] = [:]
        for (index, photo) in photos.enumerated() {
            if let number = photo.burstNumber {
                members[number, default: []].append(index)
            }
        }
        var stops: [ReviewStop] = []
        var addedBursts: Set<Int> = []
        for photo in photos where photo.verdict == .review {
            if let number = photo.burstNumber, let burst = members[number], burst.count > 1 {
                // `insert` says whether the value was new (like `Set.add` reporting it in TypeScript).
                guard addedBursts.insert(number).inserted else { continue }
                let burstPhotos = burst.map { photos[$0] }
                stops.append(ReviewStop(
                    kind: .burst(number: number),
                    photoIds: burstPhotos.map(\.id),
                    reviewIds: burstPhotos.filter { $0.verdict == .review }.map(\.id)
                ))
            } else {
                stops.append(ReviewStop(kind: .single, photoIds: [photo.id], reviewIds: [photo.id]))
            }
        }
        return stops
    }
}

/// What became of the photos that were « À revoir » when the review started.
struct ReviewSummary: Equatable, Sendable {
    var kept = 0
    var rejected = 0
    var toReview = 0

    var total: Int { kept + rejected + toReview }
}

/// One review of a gallery: the stops (frozen when it starts), where the user is, and the decisions.
///
/// The list of stops never changes once built: deciding a photo does not move the others, and the
/// counter « 12 sur 412 » keeps its meaning. What each stop shows (verdicts, best photo) is read live.
@MainActor
@Observable
final class ReviewSession {
    let galleryId: UUID
    let stops: [ReviewStop]
    /// The current stop; `stops.count` is the summary at the end.
    private(set) var position = 0
    /// The photo shown next to the best one (burst) or alone, sorted by P / U / X / B.
    private(set) var focusedPhotoId: UUID?
    /// True while the review takes the window. Escape sets it to false and keeps the position.
    var isOpen = false
    /// The gallery's photos as they are now, by id (updated by the view after every save).
    private var photos: [UUID: BurstStacks.Input] = [:]

    init(galleryId: UUID, photos: [BurstStacks.Input]) {
        self.galleryId = galleryId
        stops = ReviewQueue.stops(for: photos)
        update(photos)
        focusedPhotoId = defaultFocus(at: 0)
    }

    /// Called when the photos change (a verdict, a best photo): the stops stay, their content follows.
    func update(_ photos: [BurstStacks.Input]) {
        self.photos = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Reading

    var currentStop: ReviewStop? {
        stops.indices.contains(position) ? stops[position] : nil
    }

    /// Past the last stop: the summary is shown.
    var isFinished: Bool { position >= stops.count }

    func photo(_ id: UUID) -> BurstStacks.Input? { photos[id] }

    /// The photos of a stop still in the gallery (one may have gone to the trash meanwhile).
    func shownIds(of stop: ReviewStop) -> [UUID] {
        stop.photoIds.filter { photos[$0] != nil }
    }

    /// The best photo (★) of a burst stop, as it is now (B changes it); nil for a single photo.
    func bestId(of stop: ReviewStop) -> UUID? {
        guard stop.isBurst else { return nil }
        let members = shownIds(of: stop).compactMap { photos[$0] }
        guard !members.isEmpty else { return nil }
        return members[BurstStacks.cover(of: Array(members.indices), in: members).index].id
    }

    /// True when the user chose the best photo of this stop's burst (B).
    func isBestChosenByUser(in stop: ReviewStop) -> Bool {
        let members = shownIds(of: stop).compactMap { photos[$0] }
        guard stop.isBurst, !members.isEmpty else { return false }
        return BurstStacks.cover(of: Array(members.indices), in: members).isChosenByUser
    }

    /// Photos of the review still « À revoir », in every stop (shown in the toolbar and on « Reprendre »).
    var remainingCount: Int { summary.toReview }

    /// The photos that were « À revoir » at the start, counted by their verdict now.
    var summary: ReviewSummary {
        var summary = ReviewSummary()
        for id in stops.flatMap(\.reviewIds) {
            switch photos[id]?.verdict {
            case .keep: summary.kept += 1
            case .reject: summary.rejected += 1
            case .review: summary.toReview += 1
            case .unknown, nil: break
            }
        }
        return summary
    }

    // MARK: - Moving

    /// → : the next photo of the burst, else the next stop (a single photo is skipped).
    func moveForward() {
        guard let stop = currentStop else { return }
        let ids = shownIds(of: stop)
        if stop.isBurst, let focusedPhotoId, let index = ids.firstIndex(of: focusedPhotoId), index + 1 < ids.count {
            self.focusedPhotoId = ids[index + 1]
        } else {
            goToStop(position + 1)
        }
    }

    /// ← : the previous photo of the burst, else the previous stop. From the summary, the last stop.
    func moveBack() {
        guard let stop = currentStop else {
            goToStop(stops.count - 1)
            return
        }
        let ids = shownIds(of: stop)
        if stop.isBurst, let focusedPhotoId, let index = ids.firstIndex(of: focusedPhotoId), index > 0 {
            self.focusedPhotoId = ids[index - 1]
        } else if position > 0 {
            goToStop(position - 1)
        }
    }

    /// Space (« Rafale suivante », « Passer »): the next stop, everything left as it is.
    func skip() {
        guard !isFinished else { return }
        goToStop(position + 1)
    }

    /// Shows a stop (the summary for `stops.count`), on its default photo.
    func goToStop(_ index: Int) {
        position = min(max(index, 0), stops.count)
        focusedPhotoId = defaultFocus(at: position)
    }

    /// A click on a thumbnail of the burst.
    func focus(_ photoId: UUID) {
        guard currentStop?.photoIds.contains(photoId) == true else { return }
        focusedPhotoId = photoId
    }

    /// After ⌘Z (or ⇧⌘Z): back to the stop of the photo that changed, so the user sees it.
    func reveal(_ photoId: UUID) {
        guard let index = stops.firstIndex(where: { $0.photoIds.contains(photoId) }) else { return }
        position = index
        // The best photo is already shown large: the default photo is compared with it.
        focusedPhotoId = photoId == bestId(of: stops[index]) ? defaultFocus(at: index) : photoId
    }

    /// The first « À revoir » photo that is not the best one; else the first other photo, else the best.
    private func defaultFocus(at position: Int) -> UUID? {
        guard stops.indices.contains(position) else { return nil }
        let stop = stops[position]
        let ids = shownIds(of: stop)
        let best = bestId(of: stop)
        return ids.first { $0 != best && photos[$0]?.verdict == .review }
            ?? ids.first { $0 != best }
            ?? ids.first
    }

    // MARK: - Deciding

    /// Return on a burst: « Garder la ★, rejeter les autres », then the next stop. The photos the user
    /// chose to keep (P) stay kept: only the others are rejected. Returns false outside a burst.
    @discardableResult
    func keepBestRejectOthers(using sorter: ManualSorter) -> Bool {
        guard let stop = currentStop, let best = bestId(of: stop) else { return false }
        let others = shownIds(of: stop).filter { id in
            id != best && !(photos[id]?.isVerdictChosenByUser == true && photos[id]?.verdict == .keep)
        }
        sorter.keep(best, rejecting: others)
        goToStop(position + 1)
        return true
    }

    /// P / U / X / A on the photo shown, then the next photo (burst) or the next stop (single photo).
    @discardableResult
    func sort(_ command: SortingCommand, using sorter: ManualSorter) -> Bool {
        guard let focusedPhotoId else { return false }
        sorter.apply(command, to: [focusedPhotoId])
        moveForward()
        return true
    }

    /// B: the photo shown becomes the best of its burst. Returns false for a single photo.
    @discardableResult
    func chooseBest(using sorter: ManualSorter) -> Bool {
        guard let stop = currentStop, stop.isBurst, let focusedPhotoId else { return false }
        sorter.chooseBurstCover(focusedPhotoId)
        return true
    }
}

/// What the « Revoir » button and the « Galerie » menu offer for a gallery.
enum ReviewEntryPoint: Equatable, Sendable {
    /// No review under way: a new one over the `count` « À revoir » photos.
    case start(count: Int)
    /// A review left with Escape, `remaining` photos still « À revoir ».
    case resume(remaining: Int)

    /// « Revoir les 14 », « Reprendre la revue (reste 9) ».
    var title: String {
        switch self {
        case .start(let count): String(localized: "Revoir les \(count)")
        case .resume(let remaining): String(localized: "Reprendre la revue (reste \(remaining))")
        }
    }

    /// « Revoir les 14 », « Reprendre (9) »: when the filters leave little room.
    var shortTitle: String {
        switch self {
        case .start(let count): String(localized: "Revoir les \(count)")
        case .resume(let remaining): String(localized: "Reprendre (\(remaining))")
        }
    }

    /// The number alone, next to the play symbol.
    var count: Int {
        switch self {
        case .start(let count): count
        case .resume(let remaining): remaining
        }
    }

    var menuTitle: String {
        switch self {
        case .start: String(localized: "Revoir les photos à revoir…")
        case .resume: String(localized: "Reprendre la revue…")
        }
    }

    /// VoiceOver: the whole sentence, with the shortcut.
    var accessibilityLabel: String {
        switch self {
        case .start(let count):
            String(localized: "Revoir les \(count) photos à revoir, une rafale à la fois, Commande R")
        case .resume(let remaining):
            String(localized: "Reprendre la revue, \(remaining) photos encore à revoir, Commande R")
        }
    }

    var help: String {
        switch self {
        case .start:
            String(localized: "Passer en revue les photos « À revoir » : une rafale entière se décide d'une touche (⌘R).")
        case .resume:
            String(localized: "Reprendre la revue là où vous l'avez laissée (⌘R).")
        }
    }
}

/// The reviews of every gallery, kept while the app runs: leaving a review (Escape, another gallery)
/// keeps its position, and « Reprendre la revue » comes back to it.
@MainActor
@Observable
final class ReviewController {
    private var sessions: [UUID: ReviewSession] = [:]

    func session(for galleryId: UUID) -> ReviewSession? {
        sessions[galleryId]
    }

    /// The button's offer: resume a review left unfinished, else start one if there are photos to review.
    func entryPoint(galleryId: UUID, reviewCount: Int) -> ReviewEntryPoint? {
        if let session = resumable(galleryId) {
            return .resume(remaining: session.remainingCount)
        }
        return reviewCount > 0 ? .start(count: reviewCount) : nil
    }

    /// Resumes the review left unfinished, or starts a new one from the photos as they are now.
    @discardableResult
    func open(galleryId: UUID, photos: [BurstStacks.Input]) -> ReviewSession {
        let session = resumable(galleryId) ?? ReviewSession(galleryId: galleryId, photos: photos)
        sessions[galleryId] = session
        session.isOpen = true
        return session
    }

    /// Escape or « Terminer »: the position is kept, unless the review is over.
    func close(galleryId: UUID) {
        guard let session = sessions[galleryId] else { return }
        session.isOpen = false
        if session.isFinished { sessions[galleryId] = nil }
    }

    /// After a new sorting by the AI (the bursts change) or a deletion: the review starts again.
    func discard(galleryId: UUID) {
        sessions[galleryId] = nil
    }

    private func resumable(_ galleryId: UUID) -> ReviewSession? {
        guard let session = sessions[galleryId], !session.isFinished, session.remainingCount > 0 else { return nil }
        return session
    }
}

/// Words of the review, kept apart so the tests can check them.
enum ReviewText {
    /// « 12 sur 412 ».
    static func counter(position: Int, total: Int) -> String {
        String(localized: "\(min(position + 1, total)) sur \(total)")
    }

    /// « reste 1 photo à revoir », « reste 12 photos à revoir », « plus aucune photo à revoir ».
    static func remaining(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "plus aucune photo à revoir")
        case 1: String(localized: "reste 1 photo à revoir")
        default: String(localized: "reste \(count) photos à revoir")
        }
    }

    /// « Rafale de 7 photos », « Photo seule ».
    static func kind(of stop: ReviewStop, shownCount: Int) -> String {
        stop.isBurst ? String(localized: "Rafale de \(shownCount) photos") : String(localized: "Photo seule")
    }

    /// Spoken when a stop is shown: « Rafale de 7 photos, 4 sur 9, reste 12 photos à revoir ».
    static func stopAnnouncement(_ stop: ReviewStop, shownCount: Int, position: Int, total: Int, remainingCount: Int) -> String {
        [kind(of: stop, shownCount: shownCount), counter(position: position, total: total), remaining(remainingCount)]
            .joined(separator: ", ")
    }

    /// « 3 gardées », « 1 rejetée »… (French agrees the word with the number).
    static func kept(_ count: Int) -> String {
        count > 1 ? String(localized: "\(count) gardées") : String(localized: "\(count) gardée")
    }

    static func rejected(_ count: Int) -> String {
        count > 1 ? String(localized: "\(count) rejetées") : String(localized: "\(count) rejetée")
    }

    static func toReview(_ count: Int) -> String {
        String(localized: "\(count) encore à revoir")
    }

    /// « Revue terminée : 3 gardées, 9 rejetées, 2 encore à revoir. »
    static func summaryAnnouncement(_ summary: ReviewSummary) -> String {
        String(localized: "Revue terminée") + " : "
            + [kept(summary.kept), rejected(summary.rejected), toReview(summary.toReview)].joined(separator: ", ") + "."
    }
}
