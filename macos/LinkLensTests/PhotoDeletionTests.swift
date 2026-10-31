import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import LinkLens

// Deleting photos inside a gallery, and the multi-selection it starts from.
//
// Almost every test puts the files in a `FolderTrash`: a temporary folder standing in for the trash, so
// the user's trash is never filled. The one test with the real trash uses unique file names (the trash
// is shared by the tests running at the same time) and removes what it left. The catalogue is in memory.

// MARK: - Multi-selection (pure logic)

@MainActor
struct MultiSelectionTests {
    private let ids = (0..<6).map { _ in UUID() }

    private func browser(columns: Int = 3, inputs: [BurstStacks.Input]? = nil) -> GalleryBrowser {
        let browser = GalleryBrowser()
        browser.setPhotos(inputs ?? ids.map { BurstStacks.Input(id: $0) })
        browser.columnCount = columns
        return browser
    }

    @Test func commandAndShiftClicksSelectSeveralPhotos() {
        let browser = browser()
        browser.click(ids[0], modifier: .none)
        #expect(browser.selectedIds == [ids[0]])

        browser.click(ids[2], modifier: .command)
        #expect(browser.selectedIds == [ids[0], ids[2]])
        #expect(browser.selection == ids[2], "the last photo clicked is the current one")

        // ⇧: from the last photo clicked without ⇧ (the anchor, here 2) to this one.
        browser.click(ids[4], modifier: .shift)
        #expect(browser.orderedSelection == [ids[2], ids[3], ids[4]])
        #expect(browser.selection == ids[4])

        // ⌘ on a selected photo takes it out; the current photo stays.
        browser.click(ids[2], modifier: .command)
        #expect(browser.orderedSelection == [ids[3], ids[4]])
        #expect(browser.selection == ids[4])
        // ⌘ on the current photo: the selected photo before it becomes current.
        browser.click(ids[4], modifier: .command)
        #expect(browser.orderedSelection == [ids[3]])
        #expect(browser.selection == ids[3])

        // A plain click selects one photo again.
        browser.click(ids[5], modifier: .none)
        #expect(browser.selectedIds == [ids[5]])
        #expect(!browser.isMultipleSelection)
    }

    @Test func commandAAndEscape() {
        let browser = browser()
        browser.selection = ids[1]
        browser.selectAll()
        #expect(browser.selectedIds == Set(ids))
        #expect(browser.selection == ids[1], "the current photo stays")

        #expect(browser.clearSelection())
        #expect(browser.selectedIds.isEmpty)
        #expect(browser.selection == nil)
        #expect(!browser.clearSelection(), "nothing left to deselect: Escape goes elsewhere")
    }

    @Test func shiftArrowsGrowAndShrinkFromTheAnchor() {
        let browser = browser(columns: 3)
        browser.selection = ids[1]
        browser.extend(.right)
        #expect(browser.orderedSelection == [ids[1], ids[2]])
        browser.extend(.down)
        #expect(browser.orderedSelection == Array(ids[1...5]))
        browser.extend(.up)
        #expect(browser.orderedSelection == [ids[1], ids[2]], "back up: the range shrinks")
        // A plain arrow selects one photo again.
        browser.move(.left)
        #expect(browser.selectedIds == [ids[1]])
    }

    @Test func theTableSelectsSeveralRowsAndFollowsTheLastOne() {
        let browser = browser()
        browser.tableSelection = [ids[1]]
        #expect(browser.selection == ids[1])
        browser.tableSelection = [ids[1], ids[3]]
        #expect(browser.selection == ids[3], "the row just added is the current one (inspector, viewer)")
        browser.tableSelection = [ids[1], ids[2], ids[3]]
        #expect(browser.selection == ids[2])
        browser.tableSelection = [ids[3]]
        #expect(browser.selection == ids[3])
        #expect(browser.selectedIds == [ids[3]])
        browser.tableSelection = []
        #expect(browser.selection == nil)
    }

    @Test func aCollapsedBurstIsSelectedThroughItsBestPhoto() {
        // 1, 2, 3 are a burst whose best photo is 2.
        let inputs = ids.enumerated().map { index, id in
            BurstStacks.Input(id: id, burstNumber: (1...3).contains(index) ? 1 : nil, isBestOfBurst: index == 2)
        }
        let browser = browser(inputs: inputs)
        #expect(browser.photoIds == [ids[0], ids[2], ids[4], ids[5]], "collapsed: the stack shows the best photo")

        browser.selectAll()
        #expect(browser.selectedIds == [ids[0], ids[2], ids[4], ids[5]], "the stack stands for its best photo only")

        browser.selectWholeBurst(1)
        #expect(browser.expandedBursts == [1], "« Sélectionner toute la rafale » opens it…")
        #expect(browser.orderedSelection == [ids[1], ids[2], ids[3]], "… and selects every photo, visible")

        browser.toggleBurst(1)
        #expect(browser.selectedIds == [ids[2]], "closed again: only what is shown stays selected")
    }

    @Test func removedPhotosLeaveTheSelectionAndTheNextPhotoIsSelected() {
        let browser = browser()
        browser.click(ids[2], modifier: .none)
        browser.click(ids[3], modifier: .shift)
        // 2 and 3 went to the trash.
        browser.setPhotos([0, 1, 4, 5].map { BurstStacks.Input(id: ids[$0]) })
        #expect(browser.selectedIds == [ids[4]])
        #expect(browser.selection == ids[4], "the next photo shown takes their place")

        // The last photos: the one before them.
        browser.selection = ids[5]
        browser.setPhotos([0, 1, 4].map { BurstStacks.Input(id: ids[$0]) })
        #expect(browser.selection == ids[4])
    }

    @Test func anotherFilterKeepsOnlyTheShownPhotosSelected() {
        let verdicts: [CullingVerdict] = [.keep, .reject, .review, .reject, .keep, .keep]
        let browser = browser(inputs: zip(ids, verdicts).map { BurstStacks.Input(id: $0, verdict: $1) })
        browser.selectAll()
        browser.setFilter(.reject)
        #expect(browser.selectedIds == [ids[1], ids[3]])
    }

    @Test func clickModifiersFromTheKeyboardState() {
        #expect(GalleryBrowser.ClickModifier.held([]) == .none)
        #expect(GalleryBrowser.ClickModifier.held(.command) == .command)
        #expect(GalleryBrowser.ClickModifier.held(.shift) == .shift)
        #expect(GalleryBrowser.ClickModifier.held([.command, .shift]) == .command)
    }

    // MARK: ⌘⌫

    @Test func commandBackspaceDeletesThePhotosWhenTheyHaveTheKeyboard() {
        let photos = DeleteShortcutTarget(photosHaveFocus: true)
        #expect(photos == .photos)
        #expect(photos.shortcut(for: .photos) == DeleteShortcutTarget.shortcut)
        #expect(photos.shortcut(for: .gallery) == nil, "never both")
    }

    @Test func commandBackspaceDeletesTheGalleryOtherwise() {
        // Focus in the sidebar, the inspector or nowhere: as before batch 3.
        let gallery = DeleteShortcutTarget(photosHaveFocus: false)
        #expect(gallery == .gallery)
        #expect(gallery.shortcut(for: .gallery) == DeleteShortcutTarget.shortcut)
        #expect(gallery.shortcut(for: .photos) == nil)
    }
}

// MARK: - Sorting several photos at once

@MainActor
struct MultiSortingTests {
    @Test func oneKeySortsTheWholeSelectionAndOneUndoPutsItBack() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        var photos: [Photo] = []
        for (index, verdict) in [CullingVerdict.keep, .review, .keep, .keep].enumerated() {
            let photo = Photo(draft: makeDraft("\(index).ARW", second: index))
            context.insert(photo)
            try photo.apply(CullingResult(photoId: photo.id, verdict: verdict, reasons: []), analyzedAt: .now)
            photos.append(photo)
        }
        try context.save()
        let browser = GalleryBrowser()
        browser.setPhotos(photos.map(\.burstInput))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let sorter = ManualSorter(browser: browser, context: context, undoManager: undoManager)

        browser.click(photos[0].id, modifier: .none)
        browser.click(photos[2].id, modifier: .shift)
        undoManager.beginUndoGrouping()
        #expect(sorter.applyToSelection(.choose(.reject), advance: true))
        undoManager.endUndoGrouping()

        #expect(photos.prefix(3).allSatisfy { $0.verdict == .reject })
        #expect(photos[3].verdict == .keep, "not selected")
        #expect(browser.selectedIds.count == 3, "the selection stays: no jump to the next photo")

        undoManager.undo()
        #expect(photos.map(\.verdict) == [.keep, .review, .keep, .keep], "one ⌘Z for the three")
        #expect(!undoManager.canUndo)

        // B needs one photo: with several selected it does nothing.
        browser.selectAll()
        #expect(!sorter.chooseSelectedBurstCover())
    }
}

// MARK: - Bursts after a deletion

struct BurstAfterDeletionTests {
    @Test func aBurstLeftWithOnePhotoIsShownAsASinglePhoto() {
        let alone = UUID()
        let entries = BurstStacks.entries(for: [BurstStacks.Input(id: alone, burstNumber: 3, isBestOfBurst: false)], expanded: [])
        #expect(entries.count == 1)
        #expect(entries[0].burst == nil, "no « rafale de 1 »")
    }

    @Test func theNextBestPhotoGoesByVerdictThenScoreThenSharpness() {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        func candidate(_ id: UUID, _ verdict: CullingVerdict?, _ aesthetics: Double?, _ sharpness: Double? = nil) -> BurstStacks.CoverCandidate {
            BurstStacks.CoverCandidate(id: id, verdict: verdict, aesthetics: aesthetics, sharpness: sharpness)
        }
        #expect(BurstStacks.nextCover(among: [candidate(a, .review, 0.9), candidate(b, .keep, 0.1)]) == b, "a photo to keep first")
        #expect(BurstStacks.nextCover(among: [candidate(a, .keep, 0.2), candidate(b, .keep, 0.6)]) == b, "then the best score")
        #expect(BurstStacks.nextCover(among: [candidate(a, .keep, 0.5, 0.1), candidate(b, .keep, 0.5, 0.4)]) == b, "then the sharpest")
        #expect(BurstStacks.nextCover(among: [candidate(c, .reject, nil), candidate(d, .reject, nil)]) == c, "then the first")
        #expect(BurstStacks.nextCover(among: []) == nil)
    }
}

// MARK: - Last checks before the move

struct PhotoTrashCheckTests {
    @Test func onlyAnUnchangedRegularFileInsideTheGalleryIsMoved() throws {
        let folder = try TestFolder()
        let elsewhere = try TestFolder()
        defer {
            folder.remove()
            elsewhere.remove()
        }
        let file = try folder.writeFile("Jour 1/A.JPG", contents: "abcd")
        let stamp = try #require(FileStamp.read(file))
        func check(_ path: String, size: Int64 = 4, expected: FileStamp? = nil) -> PhotoTrasher.Check {
            PhotoTrasher.check(PhotoTrashItem(photoId: UUID(), relativePath: path, fileSize: size), in: folder.url, expected: expected)
        }

        #expect(check("Jour 1/A.JPG") == .ready(file, stamp))
        #expect(check("Jour 1/A.JPG", expected: stamp) == .ready(file, stamp))
        #expect(check("Jour 1/A.JPG", size: 5) == .skip(.notIdentical), "another size than at indexing")
        let otherDate = FileStamp(size: 4, modifiedAt: Date(timeIntervalSince1970: 0))
        #expect(check("Jour 1/A.JPG", expected: otherDate) == .skip(.notIdentical), "changed since the window opened")
        #expect(check("Jour 1/B.JPG") == .skip(.missing))
        #expect(check("../\(elsewhere.url.lastPathComponent)/A.JPG") == .skip(.outsideGallery))
        #expect(check("/etc/hosts") == .skip(.outsideGallery))

        // A folder inside the gallery that is a link to another place: never followed.
        try elsewhere.writeFile("C.JPG", contents: "abcd")
        try FileManager.default.createSymbolicLink(at: folder.url.appending(path: "Lien"), withDestinationURL: elsewhere.url)
        #expect(check("Lien/C.JPG") == .skip(.outsideGallery))
        // A file that is a link: not a regular file, never moved (nor what it points to).
        try FileManager.default.createSymbolicLink(at: folder.url.appending(path: "D.JPG"), withDestinationURL: elsewhere.url.appending(path: "C.JPG"))
        #expect(check("D.JPG") == .skip(.missing))
    }
}

// MARK: - Putting photos in the trash, and back

@MainActor
struct PhotoDeletionControllerTests {
    @Test func trashesTheSelectionAndUndoesEverything() async throws {
        let setup = try await Setup.make(files: ["DSC1.JPG", "DSC2.JPG", "DSC3.JPG"])
        defer { setup.remove() }
        try await setup.sortLikeAUser()
        let before = try setup.catalogue()
        let files = try setup.folder.snapshot()
        let thumbnails = try setup.addThumbnails()
        let ids = try setup.ids(["DSC1.JPG", "DSC2.JPG"])

        try await setup.open(ids)
        #expect(setup.controller.stamps?.count == 2, "both files looked at")
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(setup.controller.request == nil, "the window closed")
        #expect(setup.controller.report == nil, "nothing stayed in place")
        #expect(try setup.catalogue().map(\.relativePath) == ["DSC3.JPG"])
        #expect(try setup.photoCount() == 1)
        #expect(try setup.folder.snapshot().keys.sorted() == ["DSC3.JPG"])
        #expect(try setup.trashFolder.snapshot().count == 2, "in the trash, not deleted")
        #expect(setup.controller.banner?.kind == .trashed(count: 2, keptInPlace: 0))
        #expect(thumbnails.allSatisfy(setup.cache.contains), "kept while « Annuler » is possible")
        #expect(setup.queue.pending().values.first.map { Set($0) } == Set(ids))
        #expect(setup.undoManager.undoActionName == "Mise à la corbeille de 2 photos")

        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()

        #expect(try setup.folder.snapshot() == files, "back at their place, unchanged")
        #expect(try setup.trashFolder.snapshot().isEmpty)
        #expect(try setup.catalogue() == before, "same ids, choices, verdicts, bursts and best photos")
        #expect(try setup.photoCount() == 3)
        #expect(thumbnails.allSatisfy(setup.cache.contains), "same ids: the same thumbnails")
        #expect(setup.queue.pending().isEmpty)
        #expect(setup.controller.banner?.kind == .restored(count: 2, problem: nil))
        #expect(!setup.undoManager.canUndo, "no redo: deleting again needs a new confirmation")
    }

    @Test func theRealTrashTakesTheFileAndGivesItBack() async throws {
        let name = "DSC-\(UUID().uuidString.prefix(8)).JPG"
        let setup = try await Setup.make(files: [name], trash: { _ in FinderTrash() })
        defer { setup.remove() }
        let files = try setup.folder.snapshot()
        try await setup.open(try setup.ids([name]))
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: setup.folder.url.appending(path: name).path))
        #expect(setup.controller.banner?.canUndo == true)

        let recordId = try #require(setup.controller.banner?.recordId)
        setup.controller.undo(recordId: recordId)
        await setup.controller.waitUntilIdle()
        #expect(try setup.folder.snapshot() == files)
        #expect(try setup.catalogue().count == 1)
    }

    @Test func rejectedMeansTheVerdictShownUserChoiceFirst() async throws {
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        defer { setup.remove() }
        let ids = try setup.ids(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        try await setup.store.saveCulling([
            CullingResult(photoId: ids[0], verdict: .reject, reasons: []),
            CullingResult(photoId: ids[1], verdict: .keep, reasons: []),
            CullingResult(photoId: ids[2], verdict: .reject, reasons: []),
            CullingResult(photoId: ids[3], verdict: .review, reasons: []),
        ], analyzedAt: .now)
        let context = ModelContext(setup.container)
        let photos = try context.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.relativePath)]))
        photos[0].userVerdictRaw = "keep"   // the AI said Rejeter, the user keeps it
        photos[1].userVerdictRaw = "reject" // the AI said Garder, the user rejects it
        try context.save()
        let gallery = try #require(try context.fetch(FetchDescriptor<Gallery>()).first)

        let request = PhotoDeletionRequest.rejected(in: gallery, photos: photos)
        #expect(request.kind == .rejected)
        #expect(request.items.map(\.relativePath) == ["B.JPG", "C.JPG"])
        #expect(PhotoDeletionText.title(count: 2, kind: .rejected) == "Mettre les 2 photos rejetées à la corbeille ?")
    }

    @Test func anUnpluggedDiskGreysTheActionOut() async throws {
        let setup = try await Setup.make(files: ["A.JPG"])
        defer { setup.remove() }
        let unplugged = GalleryAvailability.diskDisconnected(volumeName: "DATA")
        setup.controller.galleryAvailability = { _ in unplugged }

        #expect(!setup.controller.canRequest(galleryId: setup.galleryId))
        #expect(setup.controller.blockReason(galleryId: setup.galleryId) == unplugged.help(for: .trash))
        setup.controller.requestDeletion(try setup.request(setup.ids(["A.JPG"])), undoManager: setup.undoManager)
        #expect(setup.controller.request == nil, "no window")
    }

    @Test func aDiskUnpluggedAfterTheWindowOpenedStopsEverything() async throws {
        let setup = try await Setup.make(files: ["A.JPG"])
        defer { setup.remove() }
        let files = try setup.folder.snapshot()
        try await setup.open(try setup.ids(["A.JPG"]))
        setup.controller.galleryAvailability = { _ in .diskDisconnected(volumeName: "DATA") }
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(setup.controller.request != nil, "the window stays open with the reason")
        #expect(setup.controller.errorMessage?.hasPrefix("Rien n'a été déplacé.") == true)
        #expect(try setup.folder.snapshot() == files)
        #expect(try setup.catalogue().count == 1)
    }

    @Test func aFileChangedSinceTheWindowOpenedStaysInPlace() async throws {
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG", "C.JPG"])
        defer { setup.remove() }
        try await setup.open(try setup.ids(["A.JPG", "B.JPG", "C.JPG"]))
        // B: rewritten with other content (another size). C: same size, another date (edited in place).
        try setup.folder.writeFile("B.JPG", contents: "edited by another app")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: setup.folder.url.appending(path: "C.JPG").path)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try setup.catalogue().map(\.relativePath) == ["B.JPG", "C.JPG"])
        #expect(try setup.folder.snapshot().keys.sorted() == ["B.JPG", "C.JPG"])
        let report = try #require(setup.controller.report)
        #expect(report.trashedCount == 1)
        #expect(report.skipped.map(\.reason) == [.notIdentical, .notIdentical])
        #expect(setup.controller.banner?.kind == .trashed(count: 1, keptInPlace: 2))
    }

    @Test func aRefusedTrashNeverDeletesAndOffersToRemoveFromLinkLensOnly() async throws {
        // As on an exFAT disk without a trash: `trashItem` throws.
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG"], trash: { _ in RefusingTrash() })
        defer { setup.remove() }
        let files = try setup.folder.snapshot()
        let before = try setup.catalogue()
        try await setup.open(try setup.ids(["A.JPG", "B.JPG"]))
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try setup.folder.snapshot() == files, "never deleted for good instead")
        #expect(try setup.catalogue() == before, "nothing left the catalogue")
        #expect(setup.controller.banner == nil, "nothing to undo")
        #expect(!setup.undoManager.canUndo)
        let report = try #require(setup.controller.report)
        #expect(report.trashWasRefused)
        #expect(report.trashedCount == 0)
        #expect(report.skipped.map(\.item.relativePath) == ["A.JPG", "B.JPG"])
        #expect(PhotoDeletionText.reportTitle(report) == "La corbeille a refusé ces fichiers")

        // « Retirer seulement de LinkLens (garder les fichiers) ».
        setup.controller.removeSkippedFromLibrary()
        await setup.controller.waitUntilIdle()
        #expect(setup.controller.report == nil)
        #expect(try setup.catalogue().isEmpty)
        #expect(try setup.folder.snapshot() == files, "the files did not move")
        #expect(setup.controller.banner?.kind == .removedFromLibrary(count: 2))

        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue() == before)
    }

    @Test func aPartlyRefusedTrashKeepsTheOthersUndoable() async throws {
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG", "C.JPG"], trash: { SelectiveTrash(refused: "B.JPG", base: FolderTrash(directory: $0)) })
        defer { setup.remove() }
        let files = try setup.folder.snapshot()
        try await setup.open(try setup.ids(["A.JPG", "B.JPG", "C.JPG"]))
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try setup.catalogue().map(\.relativePath) == ["B.JPG"])
        #expect(setup.controller.report?.skipped.map(\.item.relativePath) == ["B.JPG"])
        #expect(setup.controller.banner?.kind == .trashed(count: 2, keptInPlace: 1))

        setup.controller.dismissReport()
        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.folder.snapshot() == files)
        #expect(try setup.catalogue().count == 3)
    }

    @Test func removingFromLinkLensOnlyFromTheWindowKeepsTheFiles() async throws {
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG"])
        defer { setup.remove() }
        let files = try setup.folder.snapshot()
        try await setup.open(try setup.ids(["A.JPG"]))
        setup.controller.removeFromLibraryOnly()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue().map(\.relativePath) == ["B.JPG"])
        #expect(try setup.folder.snapshot() == files)
        #expect(setup.undoManager.undoActionName == "Retrait d'une photo")
    }

    @Test func theBestPhotoOfABurstGoingGivesTheStarToTheNextBestAndUndoTakesItBack() async throws {
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        defer { setup.remove() }
        let ids = try setup.ids(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        // A, B, C: a burst whose best photo is A. B is « À revoir » with a better score than C (« Garder »).
        try await setup.store.saveCulling([
            CullingResult(photoId: ids[0], verdict: .keep, reasons: [], burstNumber: 1, isBestOfBurst: true, sharpness: 0.9, aesthetics: 0.8),
            CullingResult(photoId: ids[1], verdict: .review, reasons: [], burstNumber: 1, isBestOfBurst: false, sharpness: 0.5, aesthetics: 0.6),
            CullingResult(photoId: ids[2], verdict: .keep, reasons: [], burstNumber: 1, isBestOfBurst: false, sharpness: 0.7, aesthetics: 0.3),
            CullingResult(photoId: ids[3], verdict: .keep, reasons: []),
        ], analyzedAt: .now)
        try await setup.store.finishCulling(galleryId: setup.galleryId)
        let before = try setup.catalogue()

        try await setup.open([ids[0]])
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        let after = try setup.catalogue()
        #expect(after.first { $0.id == ids[2] }?.isBestOfBurst == true, "« Garder » before « À revoir »")
        #expect(after.first { $0.id == ids[1] }?.isBestOfBurst == false)
        let entries = BurstStacks.entries(for: try setup.inputs(), expanded: [])
        let stack = try #require(entries.first { $0.burst != nil })
        #expect(stack.photoId == ids[2], "the stack shows the new best photo")
        #expect(stack.burst?.count == 2, "counter updated")
        #expect(stack.burst?.showsStar(isBestOfBurst: true) == true)

        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue() == before, "A is the best photo again, C is not")
    }

    @Test func aBurstLeftWithOnePhotoIsShownAlone() async throws {
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG", "C.JPG"])
        defer { setup.remove() }
        let ids = try setup.ids(["A.JPG", "B.JPG", "C.JPG"])
        try await setup.store.saveCulling(ids.enumerated().map { index, id in
            CullingResult(photoId: id, verdict: .keep, reasons: [], burstNumber: 1, isBestOfBurst: index == 0)
        }, analyzedAt: .now)
        try await setup.open([ids[0], ids[1]])
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        let entries = BurstStacks.entries(for: try setup.inputs(), expanded: [])
        #expect(entries.map(\.photoId) == [ids[2]])
        #expect(entries[0].burst == nil)
    }

    @Test func thumbnailsLeaveTheCacheOnlyAtTheEndOfTheUndoPeriod() async throws {
        let setup = try await Setup.make(files: ["A.JPG", "B.JPG"], undoPeriod: .milliseconds(300))
        defer { setup.remove() }
        let thumbnails = try setup.addThumbnails()
        let trashedId = try setup.ids(["A.JPG"])[0]
        try await setup.open([trashedId])
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        #expect(thumbnails.allSatisfy(setup.cache.contains), "still there right after")
        let recordId = try #require(setup.controller.undoableRecordIds.first)

        for _ in 0..<40 where setup.controller.canUndo(recordId: recordId) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(!setup.controller.canUndo(recordId: recordId))
        #expect(!setup.cache.contains(trashedId), "gone once the undo is no longer possible")
        #expect(thumbnails.filter { $0 != trashedId }.allSatisfy(setup.cache.contains), "the other photo keeps its own")
        #expect(setup.queue.pending().isEmpty)
        #expect(!setup.undoManager.canUndo)
        #expect(setup.controller.banner == nil)
    }

    // MARK: Large selections

    @Test func twelveHundredFilesGoThroughTheProgressAndComeBack() async throws {
        let setup = try await Setup.makeLarge(count: 1_200)
        defer { setup.remove() }
        let ids = try setup.catalogue().map(\.id)
        let files = try setup.folder.snapshot()
        let gallery = try #require(try await setup.store.galleryLocations().first)
        let folder = try FolderBookmark.resolve(gallery.folderBookmark)

        let reported = TrashProgressLog()
        let trasher = PhotoTrasher(store: setup.store, trash: FolderTrash(directory: setup.trashFolder.url), batchSize: 500)
        let items = try ModelContext(setup.container).fetch(FetchDescriptor<Photo>()).map(\.trashItem)
        let outcome = try await trasher.moveToTrash(items, galleryId: setup.galleryId, folder: folder, stamps: [:]) { reported.values.append($0) }

        #expect(outcome.trashed.count == 1_200)
        #expect(reported.values.count == 1_200, "one step per file for the progress pill")
        #expect(reported.values == Array(1...1_200))
        #expect(try setup.catalogue().isEmpty, "removed by batches of 500")
        #expect(Activity.photoTrash(PhotoTrashProgress(galleryId: setup.galleryId, completed: 120, total: 1_200, startedAt: .now)).text
            == "Mise à la corbeille · 120 sur \(1_200.formatted())")

        let restored = try await DuplicateTrasher(store: setup.store).restore(
            outcome.trashed, galleryNames: [setup.galleryId: "Gros"], writableFolders: [setup.galleryId: folder]
        )
        #expect(restored.restored == 1_200)
        #expect(Set(try setup.catalogue().map(\.id)) == Set(ids))
        #expect(try setup.folder.snapshot() == files)
    }

    @Test func cancellingStopsAfterTheCurrentFileAndKeepsItUndoable() async throws {
        let setup = try await Setup.makeLarge(count: 1_200, trash: { CancellingTrash(base: FolderTrash(directory: $0)) })
        defer { setup.remove() }
        let ids = try setup.catalogue().map(\.id)
        try await setup.open(ids)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(setup.controller.progress == nil, "the pill is gone")
        #expect(try setup.catalogue().count == 1_199, "the other photos were not touched")
        #expect(setup.controller.banner?.kind == .trashed(count: 1, keptInPlace: 0))
        #expect(setup.controller.report?.notReachedCount == 1_199)

        setup.controller.dismissReport()
        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue().count == 1_200)
    }

    // MARK: Texts

    @Test func frenchTexts() {
        #expect(PhotoDeletionText.title(count: 1, kind: .selection) == "Mettre 1 photo à la corbeille ?")
        #expect(PhotoDeletionText.title(count: 12, kind: .selection) == "Mettre 12 photos à la corbeille ?")
        #expect(PhotoDeletionText.trashMenuTitle(count: 1) == "Mettre à la corbeille…")
        #expect(PhotoDeletionText.trashMenuTitle(count: 3) == "Mettre les 3 photos à la corbeille…")
        #expect(PhotoDeletionText.rejectedMenuTitle(count: 26) == "Mettre les 26 photos rejetées à la corbeille…")
        #expect(PhotoDeletionText.rejectedMenuTitle(count: 1) == "Mettre la photo rejetée à la corbeille…")
        #expect(PhotoDeletionText.trashedTitle(count: 1) == "1 photo mise à la corbeille")
        #expect(PhotoDeletionText.trashedTitle(count: 4) == "4 photos mises à la corbeille")
        #expect(PhotoDeletionText.keptInPlace(1) == "1 fichier est resté à sa place.")
        #expect(PhotoDeletionText.selectedTitle(count: 3) == "3 photos sélectionnées")
        let french = Locale(identifier: "fr_FR")
        #expect(normalizedSpaces(PhotoDeletionText.filesSummary(count: 12, bytes: 296_000_000, locale: french)) == "12 fichiers · 296 Mo")
        #expect(normalizedSpaces(PhotoDeletionText.filesSummary(count: 1, bytes: 24_100_000, locale: french)) == "1 fichier · 24,1 Mo")
        let banner = PhotoDeletionBanner(recordId: UUID(), kind: .trashed(count: 3, keptInPlace: 1))
        #expect(banner.announcement == "3 photos mises à la corbeille. 1 fichier est resté à sa place. Commande Z pour annuler.")
    }
}

// MARK: - Test doubles

/// What the progress callback received (a class: the callback runs on the main actor and appends to it).
@MainActor
final class TrashProgressLog {
    var values: [Int] = []
}

/// A temporary folder standing in for the trash: the user's trash is never filled by these tests.
struct FolderTrash: FileTrashing {
    let directory: URL

    func trashItem(at url: URL) throws -> URL? {
        let destination = directory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// The trash of an exFAT disk or a network volume: always says no.
struct RefusingTrash: FileTrashing {
    func trashItem(at url: URL) throws -> URL? {
        throw CocoaError(.fileWriteVolumeReadOnly, userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// Refuses one file name, puts the others in `base`.
struct SelectiveTrash: FileTrashing {
    let refused: String
    let base: FolderTrash

    func trashItem(at url: URL) throws -> URL? {
        if url.lastPathComponent == refused { throw CocoaError(.fileWriteNoPermission) }
        return try base.trashItem(at: url)
    }
}

/// Puts the file in `base`, then cancels the task doing the deletion, as « Annuler » in the pill would.
struct CancellingTrash: FileTrashing {
    let base: FolderTrash

    func trashItem(at url: URL) throws -> URL? {
        let result = try base.trashItem(at: url)
        // Called from inside the deletion's task: cancel that task.
        withUnsafeCurrentTask { $0?.cancel() }
        return result
    }
}

// MARK: - Setup

@MainActor
private struct Setup {
    let folder: TestFolder
    let trashFolder: TestFolder
    let container: ModelContainer
    let store: LibraryStore
    let cache: ThumbnailCache
    let queue: ThumbnailPurgeQueue
    let controller: PhotoDeletionController
    let undoManager: UndoManager
    let galleryId: UUID

    /// A gallery indexed from small real JPEGs (F2), one second apart in the order given.
    static func make(
        files: [String],
        trash: (URL) -> any FileTrashing = { FolderTrash(directory: $0) },
        undoPeriod: Duration = .seconds(600)
    ) async throws -> Setup {
        let folder = try TestFolder()
        for (index, name) in files.enumerated() {
            try folder.writeJPEG(name, exifDate: String(format: "2026:09:20 14:40:%02d", index))
        }
        let base = try base(folder: folder, trash: trash, undoPeriod: undoPeriod)
        let galleryId: UUID
        switch try await FolderIndexer(store: base.store).indexFolder(at: folder.url) {
        case .indexed(let id, _), .alreadyIndexed(let id): galleryId = id
        }
        return base.with(galleryId)
    }

    /// `count` tiny files (not images) inserted straight into the catalogue: indexing them would only
    /// slow the test down.
    static func makeLarge(count: Int, trash: (URL) -> any FileTrashing = { FolderTrash(directory: $0) }) async throws -> Setup {
        let folder = try TestFolder()
        let base = try base(folder: folder, trash: trash, undoPeriod: .seconds(600))
        let galleryId = try await base.store.createGallery(
            name: "Gros", folderPath: FolderBookmark.canonicalPath(of: folder.url), folderBookmark: FolderBookmark.create(for: folder.url)
        )
        let start = Date(timeIntervalSince1970: 1_789_908_057)
        let drafts = try (0..<count).map { index in
            let name = String(format: "IMG_%04d.JPG", index)
            let url = try folder.writeFile(name, contents: "photo \(index)")
            let size = Int64(try #require(FileStamp.read(url)).size)
            return PhotoDraft(
                file: PhotoFile(url: url, relativePath: name, fileSize: size),
                metadata: PhotoMetadata(captureDate: start + Double(index), pixelWidth: 0, pixelHeight: 0),
                importedAt: start
            )
        }
        try await base.store.insert(drafts, galleryId: galleryId)
        try await base.store.finishIndexing(galleryId: galleryId)
        return base.with(galleryId)
    }

    private static func base(folder: TestFolder, trash: (URL) -> any FileTrashing, undoPeriod: Duration) throws -> Setup {
        let trashFolder = try TestFolder()
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let cache = ThumbnailCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "LinkLensPhotoDeletionThumbnails-\(UUID().uuidString)", directoryHint: .isDirectory))
        let queue = ThumbnailPurgeQueue(fileURL: cache.directory.appending(path: "Pending.json"))
        let controller = PhotoDeletionController(
            store: store, trash: trash(trashFolder.url), cache: cache, purgeQueue: queue,
            undoPeriod: undoPeriod, bannerDuration: .seconds(600),
            // The « Autoriser » panel answered with the gallery's own folder.
            requestWriteAccess: { URL(filePath: $0.folderPath, directoryHint: .isDirectory) }
        )
        let undoManager = UndoManager()
        // As in the app's other undo tests: no automatic grouping by event in a test.
        undoManager.groupsByEvent = false
        return Setup(
            folder: folder, trashFolder: trashFolder, container: container, store: store, cache: cache, queue: queue,
            controller: controller, undoManager: undoManager, galleryId: UUID()
        )
    }

    private func with(_ galleryId: UUID) -> Setup {
        Setup(
            folder: folder, trashFolder: trashFolder, container: container, store: store, cache: cache, queue: queue,
            controller: controller, undoManager: undoManager, galleryId: galleryId
        )
    }

    func remove() {
        folder.remove()
        trashFolder.remove()
        try? FileManager.default.removeItem(at: cache.directory)
    }

    func ids(_ names: [String]) throws -> [UUID] {
        let photos = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        return try names.map { name in try #require(photos.first { $0.relativePath == name }).id }
    }

    func request(_ ids: [UUID]) throws -> PhotoDeletionRequest {
        let photos = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        let items = try ids.map { id in try #require(photos.first { $0.id == id }).trashItem }
        return PhotoDeletionRequest(galleryId: galleryId, galleryName: folder.url.lastPathComponent, kind: .selection, items: items)
    }

    /// Opens the window and waits until the files have been looked at.
    func open(_ ids: [UUID]) async throws {
        controller.requestDeletion(try request(ids), undoManager: undoManager)
        await controller.waitUntilIdle()
        #expect(controller.request != nil)
        #expect(controller.stamps != nil)
    }

    /// Every photo of the catalogue, in a fixed order, as `PhotoSnapshot` (all the stored fields).
    func catalogue() throws -> [PhotoSnapshot] {
        try ModelContext(container).fetch(FetchDescriptor<Photo>()).map(\.snapshot).sorted { $0.relativePath < $1.relativePath }
    }

    func inputs() throws -> [BurstStacks.Input] {
        try ModelContext(container).fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.relativePath)])).map(\.burstInput)
    }

    func photoCount() throws -> Int {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Gallery>()).first).photoCount
    }

    func addThumbnails() throws -> [UUID] {
        let ids = try ModelContext(container).fetch(FetchDescriptor<Photo>()).map(\.id)
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        for id in ids {
            try Data("jpeg".utf8).write(to: cache.fileURL(for: id))
        }
        return ids
    }

    /// Verdicts, a burst with the AI's best photo, a choice and a best photo of the user.
    func sortLikeAUser() async throws {
        let ids = try ModelContext(container).fetch(FetchDescriptor<Photo>()).sorted { $0.relativePath < $1.relativePath }.map(\.id)
        try await store.saveCulling([
            CullingResult(photoId: ids[0], verdict: .keep, reasons: [], burstNumber: 1, isBestOfBurst: true, sharpness: 0.9, aesthetics: 0.8),
            CullingResult(photoId: ids[1], verdict: .reject, reasons: [CullingReason(kind: .blurry, verdict: .reject, value: 0.1, threshold: 0.3, onSubject: true)], burstNumber: 1, isBestOfBurst: false, sharpness: 0.1, aesthetics: 0.2),
            CullingResult(photoId: ids[2], verdict: .review, reasons: [], sharpness: 0.5, aesthetics: 0.4),
        ], analyzedAt: Date(timeIntervalSince1970: 1_789_908_100))
        try await store.finishCulling(galleryId: galleryId)
        let context = ModelContext(container)
        for photo in try context.fetch(FetchDescriptor<Photo>()) {
            if photo.id == ids[1] {
                photo.userVerdictRaw = "keep"
                photo.bestOfBurstChosenAt = Date(timeIntervalSince1970: 1_789_908_200)
            }
            if photo.id == ids[2] { photo.userVerdictRaw = "reject" }
        }
        try context.save()
    }
}

private func makeDraft(_ name: String, second: Int) -> PhotoDraft {
    PhotoDraft(
        file: PhotoFile(url: URL(filePath: "/tmp/\(name)"), relativePath: name, fileSize: 1_000),
        metadata: PhotoMetadata(captureDate: Date(timeIntervalSince1970: 1_789_908_057 + Double(second)), pixelWidth: 6000, pixelHeight: 4000),
        importedAt: .now
    )
}
