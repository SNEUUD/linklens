import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// The review of the « À revoir » photos: stops, moving, deciding a burst at once, undo, resume, summary.
@MainActor
struct ReviewSessionTests {
    // MARK: - Queue

    @Test func burstsBecomeOneStopInChronologicalOrder() {
        let photos = [
            input(.review),                          // 0: single photo
            input(.keep, burst: 1, best: true),      // 1–3: burst 1, one « À revoir »
            input(.review, burst: 1),
            input(.reject, burst: 1),
            input(.keep),                            // 4: nothing to review
            input(.review),                          // 5: single photo
            input(.review, burst: 2),                // 6–7: burst 2, both « À revoir »
            input(.review, burst: 2, best: true),
            input(.keep, burst: 3, best: true),      // 8–9: burst 3, nothing to review
            input(.reject, burst: 3),
        ]
        let ids = photos.map(\.id)

        let stops = ReviewQueue.stops(for: photos)

        #expect(stops.map(\.kind) == [.single, .burst(number: 1), .single, .burst(number: 2)])
        #expect(stops[0].photoIds == [ids[0]])
        #expect(stops[1].photoIds == [ids[1], ids[2], ids[3]], "the whole burst is shown, best and rejected photos included")
        #expect(stops[1].reviewIds == [ids[2]])
        #expect(stops[3].reviewIds == [ids[6], ids[7]])
    }

    @Test func manualChoicesDecideWhatIsToReview() {
        let photos = [
            input(.keep, chosenByUser: true),    // the AI said « À revoir », the user kept it: not in the review
            input(.review, chosenByUser: true),  // the user put it back to « À revoir » (U): in the review
            input(.review),
        ]

        let stops = ReviewQueue.stops(for: photos)

        #expect(stops.map(\.photoIds) == [[photos[1].id], [photos[2].id]])
    }

    @Test func aBurstOfOnePhotoIsASinglePhoto() {
        let photos = [input(.review, burst: 4, best: true)]
        #expect(ReviewQueue.stops(for: photos).map(\.kind) == [.single])
    }

    @Test func theQueueIsFrozenWhenDecisionsArrive() {
        var photos = [input(.review), input(.review), input(.review)]
        let session = ReviewSession(galleryId: UUID(), photos: photos)
        let before = session.stops

        photos[0].verdict = .keep
        photos[1].verdict = .reject
        photos.append(input(.review)) // a new « À revoir » photo while the review runs
        session.update(photos)

        #expect(session.stops == before, "deciding does not move the stops, nor does a new photo")
        #expect(ReviewText.counter(position: session.position, total: session.stops.count) == "1 sur 3")
        #expect(session.remainingCount == 1)
    }

    // MARK: - Moving

    @Test func arrowsWalkThroughTheBurstThenTheNextStop() {
        let photos = [
            input(.keep, burst: 1, best: true), input(.review, burst: 1), input(.reject, burst: 1),
            input(.review),
        ]
        let ids = photos.map(\.id)
        let session = ReviewSession(galleryId: UUID(), photos: photos)

        #expect(session.focusedPhotoId == ids[1], "starts on the « À revoir » photo, compared with the best one")
        #expect(session.bestId(of: session.stops[0]) == ids[0])

        session.moveForward()
        #expect(session.focusedPhotoId == ids[2])
        session.moveForward()
        #expect(session.position == 1, "past the last photo of the burst: the next stop")
        #expect(session.focusedPhotoId == ids[3])

        session.moveBack()
        #expect(session.position == 0)
        #expect(session.focusedPhotoId == ids[1], "back on the stop's first photo to review")
        session.moveBack()
        #expect(session.focusedPhotoId == ids[0])
        session.moveBack()
        #expect(session.position == 0, "nothing before the first stop")
        #expect(session.focusedPhotoId == ids[0])
    }

    @Test func spaceSkipsAndTheSummaryComesAtTheEnd() {
        let photos = [input(.review, burst: 1), input(.review, burst: 1, best: true), input(.review)]
        let session = ReviewSession(galleryId: UUID(), photos: photos)

        session.skip()
        #expect(session.position == 1)
        session.skip()
        #expect(session.isFinished)
        #expect(session.currentStop == nil)
        session.skip()
        #expect(session.position == 2, "nothing after the summary")

        session.moveBack()
        #expect(session.position == 1, "← from the summary: the last stop")
        #expect(!session.isFinished)
    }

    @Test func aClickFocusesOnlyAPhotoOfTheStop() {
        let photos = [input(.review, burst: 1), input(.keep, burst: 1, best: true), input(.review)]
        let session = ReviewSession(galleryId: UUID(), photos: photos)

        session.focus(photos[1].id)
        #expect(session.focusedPhotoId == photos[1].id)
        session.focus(photos[2].id)
        #expect(session.focusedPhotoId == photos[1].id, "a photo of another stop is ignored")
    }

    // MARK: - Summary and resume

    @Test func summaryCountsThePhotosThatWereToReview() {
        var photos = [
            input(.keep, burst: 1, best: true), input(.review, burst: 1), input(.review, burst: 1),
            input(.review), input(.review),
        ]
        let session = ReviewSession(galleryId: UUID(), photos: photos)
        photos[0].verdict = .reject // not to review at the start: not counted
        photos[1].verdict = .keep
        photos[2].verdict = .reject
        photos[3].verdict = .reject
        session.update(photos)

        #expect(session.summary == ReviewSummary(kept: 1, rejected: 2, toReview: 1))
        #expect(ReviewText.summaryAnnouncement(session.summary) == "Revue terminée : 1 gardée, 2 rejetées, 1 encore à revoir.")
    }

    @Test func escapeKeepsThePositionAndTheReviewResumes() {
        let controller = ReviewController()
        let galleryId = UUID()
        var photos = [input(.review), input(.review), input(.review)]
        #expect(controller.entryPoint(galleryId: galleryId, reviewCount: 3) == .start(count: 3))

        let session = controller.open(galleryId: galleryId, photos: photos)
        #expect(session.isOpen)
        session.skip()
        photos[0].verdict = .keep
        session.update(photos)
        controller.close(galleryId: galleryId)

        #expect(!session.isOpen)
        #expect(controller.entryPoint(galleryId: galleryId, reviewCount: 2) == .resume(remaining: 2))
        #expect(ReviewEntryPoint.resume(remaining: 2).title == "Reprendre la revue (reste 2)")
        let resumed = controller.open(galleryId: galleryId, photos: photos)
        #expect(resumed === session, "the same review, frozen stops and position")
        #expect(resumed.position == 1)
    }

    @Test func aFinishedReviewIsNotResumed() {
        let controller = ReviewController()
        let galleryId = UUID()
        let session = controller.open(galleryId: galleryId, photos: [input(.review), input(.review)])
        session.goToStop(session.stops.count)
        controller.close(galleryId: galleryId)

        #expect(controller.session(for: galleryId) == nil)
        #expect(controller.entryPoint(galleryId: galleryId, reviewCount: 2) == .start(count: 2), "the skipped photos make a new review")
        #expect(controller.entryPoint(galleryId: galleryId, reviewCount: 0) == nil, "nothing to review: no button")
    }

    @Test func aReviewWithNothingLeftIsNotResumed() {
        let controller = ReviewController()
        let galleryId = UUID()
        var photos = [input(.review), input(.review)]
        let session = controller.open(galleryId: galleryId, photos: photos)
        controller.close(galleryId: galleryId)
        // Both sorted in the grid meanwhile.
        photos[0].verdict = .keep
        photos[1].verdict = .reject
        session.update(photos)

        #expect(controller.entryPoint(galleryId: galleryId, reviewCount: 0) == nil)
        #expect(controller.open(galleryId: galleryId, photos: photos) !== session)
    }

    @Test func words() {
        #expect(ReviewText.counter(position: 11, total: 412) == "12 sur 412")
        #expect(ReviewText.remaining(0) == "plus aucune photo à revoir")
        #expect(ReviewText.remaining(1) == "reste 1 photo à revoir")
        // Grouped as the user's locale writes numbers (« 1 980 » in French).
        #expect(ReviewText.remaining(1_980) == "reste \(1_980.formatted()) photos à revoir")
        #expect(ReviewEntryPoint.start(count: 14).title == "Revoir les 14")
        let stop = ReviewStop(kind: .burst(number: 4), photoIds: [UUID()], reviewIds: [])
        #expect(ReviewText.stopAnnouncement(stop, shownCount: 7, position: 3, total: 9, remainingCount: 12)
            == "Rafale de 7 photos, 4 sur 9, reste 12 photos à revoir")
    }

    // MARK: - Deciding (with the catalogue and undo)

    @Test func returnKeepsTheBestAndRejectsTheOthersInOneUndoStep() throws {
        // Burst: 0 « À revoir », 1 best (AI « Garder »), 2 « À revoir », 3 « Rejeter »; then a single photo.
        let fixture = try Fixture([.review, .keep, .review, .reject, .review], burst: [0, 1, 2, 3], best: 1)
        let session = fixture.session

        #expect(fixture.decide { session.keepBestRejectOthers(using: fixture.sorter) })

        #expect(fixture.verdicts == [.reject, .keep, .reject, .reject, .review])
        #expect(fixture.photos[0..<4].allSatisfy { $0.isVerdictChosenByUser }, "the user's choices: a new sorting keeps them")
        #expect(fixture.photos.map(\.cullingVerdict) == [.review, .keep, .review, .reject, .review], "the AI's proposals are untouched")
        #expect(session.position == 1, "then the next stop")
        #expect(fixture.undoManager.undoActionName == "Garder la meilleure, rejeter les autres")

        fixture.undo()

        #expect(fixture.verdicts == [.review, .keep, .review, .reject, .review], "one ⌘Z undoes the whole burst")
        #expect(fixture.photos.allSatisfy { !$0.isVerdictChosenByUser })
        #expect(session.position == 0, "the review goes back to the burst")
        #expect(session.focusedPhotoId == fixture.photos[0].id)

        fixture.redo()
        #expect(fixture.verdicts == [.reject, .keep, .reject, .reject, .review])
    }

    @Test func returnLeavesThePhotosTheUserKept() throws {
        let fixture = try Fixture([.review, .keep, .review], burst: [0, 1, 2], best: 1)
        let session = fixture.session

        // P on the first photo: kept, and the next photo of the burst is shown.
        fixture.decide { session.sort(.choose(.keep), using: fixture.sorter) }
        #expect(session.focusedPhotoId == fixture.photos[1].id)
        fixture.decide { session.keepBestRejectOthers(using: fixture.sorter) }

        #expect(fixture.verdicts == [.keep, .keep, .reject])
    }

    @Test func returnWorksWithTheBestChosenByTheUser() throws {
        let fixture = try Fixture([.review, .keep, .review], burst: [0, 1, 2], best: 1)
        let session = fixture.session
        session.focus(fixture.photos[2].id)

        fixture.decide { session.chooseBest(using: fixture.sorter) }
        #expect(session.bestId(of: session.stops[0]) == fixture.photos[2].id)
        #expect(session.isBestChosenByUser(in: session.stops[0]))
        fixture.decide { session.keepBestRejectOthers(using: fixture.sorter) }

        #expect(fixture.verdicts == [.reject, .reject, .keep])
    }

    @Test func aSinglePhotoIsSortedThenTheNextStopIsShown() throws {
        let fixture = try Fixture([.review, .review])
        let session = fixture.session

        #expect(!session.keepBestRejectOthers(using: fixture.sorter), "Return does nothing on a single photo")
        #expect(!session.chooseBest(using: fixture.sorter))
        fixture.decide { session.sort(.choose(.reject), using: fixture.sorter) }

        #expect(fixture.verdicts == [.reject, .review])
        #expect(session.position == 1)
        fixture.decide { session.sort(.choose(.keep), using: fixture.sorter) }
        #expect(session.isFinished)
        #expect(session.summary == ReviewSummary(kept: 1, rejected: 1, toReview: 0))

        fixture.undo()
        #expect(session.position == 1, "⌘Z from the summary: back to the photo")
        #expect(fixture.verdicts == [.reject, .review])
    }

    @Test func skippingChangesNothing() throws {
        let fixture = try Fixture([.review, .keep, .review], burst: [0, 1, 2], best: 1)

        fixture.session.skip()

        #expect(fixture.verdicts == [.review, .keep, .review])
        #expect(!fixture.undoManager.canUndo)
        #expect(fixture.session.isFinished)
    }

    // MARK: - Helpers

    /// A gallery in memory, its review, a sorter with its own undo manager: as `GalleryDetailView` wires them.
    @MainActor
    private struct Fixture {
        let context: ModelContext
        let photos: [Photo]
        let undoManager = UndoManager()
        let sorter: ManualSorter
        let session: ReviewSession

        init(_ aiVerdicts: [CullingVerdict], burst: [Int] = [], best: Int? = nil) throws {
            context = ModelContext(try makeInMemoryContainer())
            var photos: [Photo] = []
            for (index, verdict) in aiVerdicts.enumerated() {
                let photo = Photo(draft: PhotoDraft(
                    file: PhotoFile(url: URL(filePath: "/tmp/\(index).ARW"), relativePath: "\(index).ARW", fileSize: 1_000),
                    metadata: PhotoMetadata(captureDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)), pixelWidth: 6000, pixelHeight: 4000),
                    importedAt: Date()
                ))
                context.insert(photo)
                photo.cullingVerdictRaw = verdict.rawValue
                if burst.contains(index) {
                    photo.burstNumber = 1
                    photo.isBestOfBurst = index == best
                }
                photos.append(photo)
            }
            try context.save()
            self.photos = photos
            // Each change is its own undo step, as one key press in the app (see macos/CLAUDE.md).
            undoManager.groupsByEvent = false
            sorter = ManualSorter(browser: nil, context: context, undoManager: undoManager)
            session = ReviewSession(galleryId: UUID(), photos: photos.map(\.burstInput))
            let session = session
            sorter.onRestore = { session.reveal($0) }
        }

        var verdicts: [CullingVerdict?] { photos.map(\.verdict) }

        /// One key press: one undo group, then what the view does when its `@Query` sees the save.
        @discardableResult
        func decide(_ action: () -> Bool) -> Bool {
            undoManager.beginUndoGrouping()
            let result = action()
            undoManager.endUndoGrouping()
            refresh()
            return result
        }

        func undo() {
            undoManager.undo()
            refresh()
        }

        func redo() {
            undoManager.redo()
            refresh()
        }

        func refresh() {
            session.update(photos.map(\.burstInput))
        }
    }
}

/// What the review needs to know about a photo, without the catalogue.
private func input(_ verdict: CullingVerdict, burst: Int? = nil, best: Bool = false, chosenByUser: Bool = false) -> BurstStacks.Input {
    BurstStacks.Input(id: UUID(), burstNumber: burst, isBestOfBurst: best, verdict: verdict, isVerdictChosenByUser: chosenByUser)
}
