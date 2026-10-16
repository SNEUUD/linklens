import CoreGraphics
import Foundation
import Testing
@testable import LinkLens

/// Logic of the full-window viewer (batch 4): filmstrip, navigation under a filter, context line,
/// the AI's reason in one sentence, 100 % zoom framing.
@MainActor
struct ViewerTextTests {
    /// 4 single photos, a burst of 5 (best: its 3rd photo), 4 single photos.
    private func inputs() -> [BurstStacks.Input] {
        (0..<13).map { index in
            let inBurst = (4...8).contains(index)
            let verdict: CullingVerdict = index % 3 == 0 ? .review : .keep
            return BurstStacks.Input(id: UUID(), burstNumber: inBurst ? 1 : nil, isBestOfBurst: index == 6, verdict: verdict)
        }
    }

    // MARK: - Filmstrip

    @Test func anOpenBurstShowsItsPhotosWithTheNeighboursDimmed() {
        let photos = inputs()
        let entries = BurstStacks.entries(for: photos, expanded: [1])
        let strip = Filmstrip.make(entries: entries, selection: photos[6].id)
        #expect(strip.items.map(\.photoId) == photos[4...8].map(\.id))
        #expect(strip.leading?.photoId == photos[3].id)
        #expect(strip.trailing?.photoId == photos[9].id)
        #expect(strip.burstNumber == 1)
    }

    @Test func outsideABurstTheStripShowsTheNeighbours() {
        let photos = inputs()
        let entries = BurstStacks.entries(for: photos, expanded: [])
        // Entries: 0 1 2 3 [burst] 9 10 11 12 = 9 entries; selection 10 is entry 6.
        let strip = Filmstrip.make(entries: entries, selection: photos[10].id, maxItems: 5)
        #expect(strip.burstNumber == nil)
        #expect(strip.items.count == 5)
        #expect(strip.items[2].photoId == photos[10].id, "the selected photo stays in the middle")
        #expect(strip.leading?.photoId == photos[3].id)
        #expect(strip.trailing == nil, "12 is the last entry, already among the items")
    }

    @Test func theStripShiftsAtTheStart() {
        let photos = inputs()
        let entries = BurstStacks.entries(for: photos, expanded: [])
        let strip = Filmstrip.make(entries: entries, selection: photos[0].id, maxItems: 5)
        #expect(strip.leading == nil)
        #expect(strip.items.first?.photoId == photos[0].id)
        #expect(strip.items.count == 5)
    }

    @Test func underAFilterTheStripFollowsTheFilteredPhotos() {
        let photos = inputs()
        let entries = BurstStacks.entries(for: photos, expanded: [], filter: .review)
        let strip = Filmstrip.make(entries: entries, selection: photos[5].id)
        // 5 is « Garder »: not shown, so nothing to show around it.
        #expect(strip == .empty)
        // 3 is « À revoir »: the strip lists only « À revoir » photos, the burst's 6 among them.
        let review = Filmstrip.make(entries: entries, selection: photos[3].id)
        #expect(review.burstNumber == nil, "a burst member shown alone is a neighbour, not an open burst")
        #expect(review.items.allSatisfy { photos[$0.photoIndex].verdict == .review })
    }

    @Test func aLongBurstIsCutAroundTheSelectedPhoto() {
        let photos = inputs()
        let entries = BurstStacks.entries(for: photos, expanded: [1])
        let strip = Filmstrip.make(entries: entries, selection: photos[8].id, maxItems: 3)
        #expect(strip.items.map(\.photoId) == photos[6...8].map(\.id))
        #expect(strip.leading?.photoId == photos[5].id, "the dimmed photo before is still in the burst")
        #expect(strip.trailing?.photoId == photos[9].id)
    }

    @Test func itemsFittingIsBounded() {
        #expect(Filmstrip.itemsFitting(width: 200, itemWidth: 52, dimmedWidth: 48) == 1)
        #expect(Filmstrip.itemsFitting(width: 5000, itemWidth: 52, dimmedWidth: 48) == Filmstrip.maximumItems)
    }

    // MARK: - Navigation

    @Test func arrowsFollowTheFilterAndStopAtBothEnds() {
        let photos = inputs()
        let browser = GalleryBrowser()
        browser.setPhotos(photos)
        browser.setFilter(.review)
        let reviewIds = photos.filter { $0.verdict == .review }.map(\.id)
        browser.openViewer(on: reviewIds[0])
        #expect(!browser.hasNeighbour(offset: -1))
        browser.showNeighbour(offset: 1)
        #expect(browser.selection == reviewIds[1], "the « Garder » photos in between are skipped")
        for _ in 0..<10 { browser.showNeighbour(offset: 1) }
        #expect(browser.selection == reviewIds.last)
        #expect(!browser.hasNeighbour(offset: 1))
    }

    // MARK: - Context line

    @Test func contextLineSaysWhereThePhotoIs() {
        let photos = inputs()
        let open = BurstStacks.entries(for: photos, expanded: [1])
        #expect(ViewerContext.line(entries: open, index: 6, photoCount: 13, filter: .all) == "Rafale 1 ouverte · photo 3 sur 5")
        #expect(ViewerContext.line(entries: open, index: 10, photoCount: 13, filter: .all) == "Photo 11 sur 13")
        let collapsed = BurstStacks.entries(for: photos, expanded: [])
        #expect(ViewerContext.line(entries: collapsed, index: 4, photoCount: 13, filter: .all) == "Rafale 1 repliée · 5 photos")
        let review = BurstStacks.entries(for: photos, expanded: [], filter: .review)
        #expect(ViewerContext.line(entries: review, index: 0, photoCount: 13, filter: .review) == "À revoir · photo 1 sur \(review.count)")
    }

    // MARK: - Reason sentence

    @Test func theAIsProposalInOneSentence() {
        let line = ViewerReasonLine(aiVerdict: .keep, userVerdict: nil, reasons: [CullingReason(kind: .bestOfBurst, verdict: .keep)], hasSubject: true)
        #expect(line.icon == .star)
        #expect(line.text == "L'IA propose Garder\u{00A0}: meilleure photo de la rafale, sujet net et entier.")
        #expect(!line.canFollowAI)
    }

    @Test func theUsersChoiceNamesTheAIsProposal() {
        let line = ViewerReasonLine(aiVerdict: .keep, userVerdict: .review, reasons: [CullingReason(kind: .bestOfBurst, verdict: .keep)], hasSubject: true)
        #expect(line.icon == .person)
        #expect(line.text == "Votre choix · l'IA proposait Garder\u{00A0}: meilleure photo de la rafale, sujet net et entier.")
        #expect(line.canFollowAI)
    }

    @Test func reasonsAreShortAndAtMostThree() {
        let reasons = [
            CullingReason(kind: .blurry, verdict: .reject, onSubject: true),
            CullingReason(kind: .subjectCut, verdict: .reject, side: .right),
            CullingReason(kind: .eyesClosed, verdict: .reject),
            CullingReason(kind: .underexposed, verdict: .review),
        ]
        #expect(ViewerReasonLine.summary(of: reasons, hasSubject: true) == "sujet flou, sujet coupé à droite, yeux fermés.")
        #expect(ViewerReasonLine.summary(of: [], hasSubject: true) == nil)
    }

    // MARK: - Zoom

    @Test func zoomCentresTheSubjectWithinThePhotosEdges() {
        let size = ZoomFraming.actualSize(pixelWidth: 4000, pixelHeight: 6000, displayScale: 2)
        #expect(size == CGSize(width: 2000, height: 3000))
        let viewport = CGSize(width: 1000, height: 600)
        // Subject centred at (0.4, 0.45): the photo moves right by 0.1 × 2000 and down by 0.05 × 3000.
        let offset = ZoomFraming.offset(photoSize: size, viewport: viewport, focus: CGPoint(x: 0.4, y: 0.45))
        #expect(abs(offset.width - 200) < 0.001 && abs(offset.height - 150) < 0.001)
        // A subject against the left edge: the photo stops at its edge.
        let edge = ZoomFraming.offset(photoSize: size, viewport: viewport, focus: CGPoint(x: 0, y: 0.5))
        #expect(edge.width == 500)
        // A photo narrower than the area stays centred.
        let small = ZoomFraming.offset(photoSize: CGSize(width: 500, height: 3000), viewport: viewport, focus: CGPoint(x: 0.1, y: 0.5))
        #expect(small.width == 0)
        #expect(ZoomFraming.focus(subject: nil) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func aDragPastTheEdgeIsNotKept() {
        let size = CGSize(width: 2000, height: 3000), viewport = CGSize(width: 1000, height: 600)
        let focus = CGPoint(x: 0, y: 0.5) // framed against the left edge (wanted 1000, shown 500)
        let pan = ZoomFraming.settledPan(photoSize: size, viewport: viewport, focus: focus, pan: CGSize(width: 300, height: 0))
        // Still at the edge, and a drag back moves the photo at once.
        #expect(ZoomFraming.offset(photoSize: size, viewport: viewport, focus: focus, pan: pan).width == 500)
        let back = CGSize(width: pan.width - 100, height: 0)
        #expect(ZoomFraming.offset(photoSize: size, viewport: viewport, focus: focus, pan: back).width == 400)
    }
}
