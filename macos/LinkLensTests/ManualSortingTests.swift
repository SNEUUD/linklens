import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import LinkLens

/// Manual sorting: the user's verdict next to the AI's proposal, keys, undo, and everything
/// that counts verdicts (counters, export, duplicates).
@MainActor
struct ManualSortingTests {
    // MARK: - Keys

    @Test func lightroomKeysGiveTheCommands() {
        #expect(SortingCommand(characters: "p", modifiers: []) == .choose(.keep))
        #expect(SortingCommand(characters: "u", modifiers: []) == .choose(.review))
        #expect(SortingCommand(characters: "x", modifiers: []) == .choose(.reject))
        #expect(SortingCommand(characters: "a", modifiers: []) == .followAI)
        #expect(SortingCommand(characters: "X", modifiers: .shift) == .choose(.reject), "Shift or Caps Lock still sort")
        #expect(SortingCommand(characters: "P", modifiers: .capsLock) == .choose(.keep))
    }

    @Test func otherKeysAndMenuShortcutsAreLeftAlone() {
        #expect(SortingCommand(characters: "s", modifiers: []) == nil, "S opens bursts")
        #expect(SortingCommand(characters: "e", modifiers: .command) == nil)
        #expect(SortingCommand(characters: "p", modifiers: .command) == nil, "⌘P belongs to the menus")
        #expect(SortingCommand(characters: "x", modifiers: .option) == nil)
        #expect(SortingCommand(characters: "u", modifiers: .control) == nil)
        #expect(SortingCommand(characters: " ", modifiers: []) == nil)
    }

    // MARK: - Stored choice

    @Test func theUserChoiceIsShownInsteadOfTheProposal() throws {
        let fixture = try Fixture(aiVerdicts: [.reject])
        let photo = fixture.photos[0]

        fixture.change(.choose(.keep), photo.id)

        #expect(photo.verdict == .keep)
        #expect(photo.cullingVerdict == .reject, "the AI's proposal is kept apart")
        #expect(photo.isVerdictChosenByUser)
        #expect(photo.verdictDescription == "Garder, votre choix, l'IA proposait Rejeter")
        #expect(try fixture.storedUserVerdicts() == ["keep"], "saved at once, visible from another context")

        fixture.change(.followAI, photo.id)

        #expect(photo.verdict == .reject)
        #expect(!photo.isVerdictChosenByUser)
        #expect(photo.verdictDescription == "Rejeter")
        #expect(try fixture.storedUserVerdicts() == [nil])
    }

    @Test func choosingTheSameVerdictAsTheAIIsStillTheUserChoice() throws {
        let fixture = try Fixture(aiVerdicts: [.keep])
        fixture.change(.choose(.keep), fixture.photos[0].id)

        #expect(fixture.photos[0].isVerdictChosenByUser, "a confirmed photo stays « Garder » if the AI changes its mind")
        #expect(fixture.photos[0].verdictDescription == "Garder, votre choix")
    }

    @Test func aVerdictFromANewerVersionIsUnknown() throws {
        let fixture = try Fixture(aiVerdicts: [.keep])
        fixture.photos[0].userVerdictRaw = "favourite"

        #expect(fixture.photos[0].verdict == .unknown)
    }

    @Test func aKeySortsTheSelectionAndMovesToTheNextPhoto() throws {
        let fixture = try Fixture(aiVerdicts: [.review, .review, .review])
        let ids = fixture.photos.map(\.id)
        fixture.browser.selection = ids[0]

        #expect(fixture.press(.choose(.reject), advance: true))
        #expect(fixture.photos[0].verdict == .reject)
        #expect(fixture.browser.selection == ids[1])

        fixture.browser.selection = ids[2]
        fixture.press(.choose(.keep), advance: true)
        #expect(fixture.browser.selection == ids[2], "the last photo stays selected")

        fixture.browser.selection = nil
        #expect(!fixture.press(.choose(.keep), advance: true), "nothing selected: the key is not used")
    }

    @Test func aCollapsedBurstSortsItsCoverOnly() throws {
        let fixture = try Fixture(aiVerdicts: [.review, .keep, .review], burst: (number: 1, best: 1))
        #expect(fixture.browser.photoIds == [fixture.photos[1].id], "collapsed: only the best photo is shown")
        fixture.browser.selection = fixture.photos[1].id

        fixture.press(.choose(.reject), advance: true)

        #expect(fixture.photos.map(\.verdict) == [.review, .reject, .review])
    }

    // MARK: - Undo

    @Test func undoAndRedoGoThroughSeveralChanges() throws {
        let fixture = try Fixture(aiVerdicts: [.review, .review])
        let (a, b) = (fixture.photos[0], fixture.photos[1])
        let undo = fixture.undoManager

        fixture.change(.choose(.keep), a)
        fixture.change(.choose(.reject), b)
        fixture.change(.choose(.reject), a)
        #expect(fixture.photos.map(\.verdict) == [.reject, .reject])
        #expect(undo.undoActionName == "Rejeter")

        undo.undo()
        #expect(fixture.photos.map(\.verdict) == [.keep, .reject])
        #expect(fixture.browser.selection == a.id, "undo selects the photo that changed")
        undo.undo()
        #expect(fixture.photos.map(\.verdict) == [.keep, .review])
        #expect(fixture.browser.selection == b.id)
        undo.undo()
        #expect(fixture.photos.map(\.verdict) == [.review, .review])
        #expect(fixture.photos.allSatisfy { !$0.isVerdictChosenByUser }, "back to the AI's proposal, not a copy of it")
        #expect(!undo.canUndo)
        #expect(try fixture.storedUserVerdicts() == [nil, nil])

        undo.redo()
        undo.redo()
        #expect(fixture.photos.map(\.verdict) == [.keep, .reject])
        undo.redo()
        #expect(fixture.photos.map(\.verdict) == [.reject, .reject])
        #expect(!undo.canRedo)
        #expect(try fixture.storedUserVerdicts() == ["reject", "reject"])
    }

    @Test func goingBackToTheAIProposalCanBeUndone() throws {
        let fixture = try Fixture(aiVerdicts: [.reject])
        let photo = fixture.photos[0]
        fixture.change(.choose(.keep), photo)
        fixture.change(.followAI, photo)
        #expect(photo.verdict == .reject)

        fixture.undoManager.undo()

        #expect(photo.verdict == .keep)
        #expect(photo.isVerdictChosenByUser)
    }

    @Test func sameVerdictAgainAddsNothingToUndo() throws {
        let fixture = try Fixture(aiVerdicts: [.review])
        fixture.change(.choose(.keep), fixture.photos[0])
        // Outside an undo group on purpose: registering an undo here would be refused by AppKit.
        #expect(!fixture.sorter.apply(.choose(.keep), to: [fixture.photos[0].id]))

        fixture.undoManager.undo()

        #expect(fixture.photos[0].verdict == .review, "one ⌘Z undoes it")
    }

    @Test func undoSelectsTheStackOfACollapsedBurst() throws {
        let fixture = try Fixture(aiVerdicts: [.review, .keep, .review], burst: (number: 1, best: 1))
        fixture.browser.toggleBurst(1)
        fixture.browser.selection = fixture.photos[2].id
        fixture.change(.choose(.reject), fixture.photos[2])
        fixture.browser.toggleBurst(1)
        fixture.browser.selection = nil

        fixture.undoManager.undo()

        #expect(fixture.photos[2].verdict == .review)
        #expect(fixture.browser.selection == fixture.photos[1].id, "the photo is hidden: its stack is selected")
    }

    // MARK: - A new AI sorting

    @Test func sortingAgainNeverReplacesAManualChoice() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("a.jpg", width: 1200, height: 800)
        try folder.writeJPEG("b.jpg", width: 1200, height: 800)
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let result = try await FolderIndexer(store: store).indexFolder(at: folder.url)
        guard case .indexed(let galleryId, _) = result else { throw LibraryError.galleryNotFound }
        let culler = GalleryCuller(store: store)
        _ = try await culler.cullGallery(id: galleryId)

        // The window's context, as in the app.
        let context = container.mainContext
        let photos = try context.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.relativePath)]))
        let proposal = try #require(photos[0].cullingVerdict)
        let choice: CullingVerdict = proposal == .keep ? .reject : .keep
        ManualSorter(browser: nil, context: context).apply(.choose(choice), to: [photos[0].id])

        _ = try await culler.cullGallery(id: galleryId)

        let fresh = try ModelContext(container).fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.relativePath)]))
        #expect(fresh[0].userVerdict == choice)
        #expect(fresh[0].cullingVerdict == proposal, "the AI's new proposal is stored next to it")
        #expect(fresh[0].verdict == choice)
        #expect(fresh[1].userVerdictRaw == nil)
    }

    /// The analysis runs in the store's own context, which may hold the photos from before the
    /// user's choice: saving the AI's results must not write that old `nil` back.
    @Test func aChoiceMadeDuringTheAnalysisSurvivesItsResults() async throws {
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await galleryWithoutFiles(["a.ARW", "b.ARW"], store: store)
        let contents = try await store.cullingContents(galleryId: galleryId)
        let ids = contents.photos.map(\.id)
        let a = try #require(contents.photos.first { $0.relativePath == "a.ARW" }?.id)

        ManualSorter(browser: nil, context: container.mainContext).apply(.choose(.keep), to: [a])
        try await store.saveCulling(ids.map { aiResult(.reject, for: $0) }, analyzedAt: Date())

        let photos = try ModelContext(container).fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.relativePath)]))
        #expect(photos.map(\.cullingVerdict) == [.reject, .reject])
        #expect(photos.map(\.verdict) == [.keep, .reject])
    }

    /// The other way round: the window still holds the photos from before a new sorting.
    @Test func aChoiceMadeAfterTheAnalysisKeepsItsResults() async throws {
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await galleryWithoutFiles(["a.ARW"], store: store)
        let context = container.mainContext
        let photo = try #require(try context.fetch(FetchDescriptor<Photo>()).first)
        #expect(photo.cullingVerdict == nil)

        try await store.saveCulling([aiResult(.reject, for: photo.id)], analyzedAt: Date())
        try await store.finishCulling(galleryId: galleryId)
        ManualSorter(browser: nil, context: context).apply(.choose(.review), to: [photo.id])

        let fresh = try #require(try ModelContext(container).fetch(FetchDescriptor<Photo>()).first)
        #expect(fresh.cullingVerdict == .reject)
        #expect(fresh.cullingReasons.map(\.kind) == [.blurry])
        #expect(fresh.verdict == .review)
    }

    // MARK: - Everything that counts verdicts

    @Test func countersUseTheShownVerdict() throws {
        let fixture = try Fixture(aiVerdicts: [.keep, .review, .review, .reject, .reject])
        fixture.change(.choose(.keep), fixture.photos[1].id)
        fixture.change(.choose(.reject), fixture.photos[0].id)
        fixture.change(.choose(.reject), fixture.photos[3].id)

        #expect(VerdictCounts(fixture.photos) == VerdictCounts(keep: 1, review: 1, reject: 3, chosenByUser: 3))
    }

    @Test func exportOfThePhotosToKeepFollowsTheUser() throws {
        let fixture = try Fixture(aiVerdicts: [.keep, .keep, .review, .reject])
        fixture.change(.choose(.reject), fixture.photos[1].id)
        fixture.change(.choose(.keep), fixture.photos[3].id)

        let exported = ExportScope.keep.photos(from: fixture.photos, selectedPhotoId: nil)

        #expect(exported.map(\.relativePath) == ["0.ARW", "3.ARW"], "« À revoir » is not exported with the photos to keep")
        #expect(ExportScope.defaultScope(for: fixture.photos) == .keep)
    }

    @Test func exportFallsBackToEverythingWhenNothingIsKeptAnyMore() throws {
        let fixture = try Fixture(aiVerdicts: [.keep, .review])
        fixture.change(.choose(.reject), fixture.photos[0].id)

        #expect(ExportScope.defaultScope(for: fixture.photos) == .all)
    }

    @Test func duplicatesSeeTheUserChoice() async throws {
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await galleryWithoutFiles(["a.ARW", "b.ARW"], store: store)
        let photos = try await store.cullingContents(galleryId: galleryId).photos
        try await store.saveCulling(photos.map { aiResult(.review, for: $0.id) }, analyzedAt: Date())
        let b = try #require(photos.first { $0.relativePath == "b.ARW" }?.id)
        ManualSorter(browser: nil, context: container.mainContext).apply(.choose(.keep), to: [b])

        let files = try await store.duplicateCatalogue().files.sorted { $0.relativePath < $1.relativePath }

        #expect(files.map(\.verdict) == [.review, .keep])
    }

    @Test func aPhotoBackFromTheTrashKeepsTheUserChoice() async throws {
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await galleryWithoutFiles(["a.ARW"], store: store)
        let id = try #require(try await store.cullingContents(galleryId: galleryId).photos.first?.id)
        ManualSorter(browser: nil, context: container.mainContext).apply(.choose(.reject), to: [id])

        let snapshots = try await store.removePhotos(ids: [id])
        try await store.restorePhotos(snapshots, galleryId: galleryId)

        let photo = try #require(try ModelContext(container).fetch(FetchDescriptor<Photo>()).first)
        #expect(photo.userVerdict == .reject)
    }

    @Test func sortingAPhotoRemovedMeanwhileDoesNothing() throws {
        let fixture = try Fixture(aiVerdicts: [.keep])
        let id = fixture.photos[0].id
        fixture.context.delete(fixture.photos[0])
        try fixture.context.save()

        #expect(!fixture.sorter.apply(.choose(.reject), to: [id]))
        #expect(!fixture.undoManager.canUndo)
    }

    // MARK: - Helpers

    /// A gallery of photos named 0.ARW, 1.ARW… with the AI's verdicts, in an in-memory catalogue.
    @MainActor
    private struct Fixture {
        let context: ModelContext
        let photos: [Photo]
        let browser = GalleryBrowser()
        let undoManager = UndoManager()
        let sorter: ManualSorter

        init(aiVerdicts: [CullingVerdict], burst: (number: Int, best: Int)? = nil) throws {
            let container = try makeInMemoryContainer()
            context = ModelContext(container)
            var photos: [Photo] = []
            for (index, verdict) in aiVerdicts.enumerated() {
                let photo = Photo(draft: draft("\(index).ARW", second: index))
                context.insert(photo)
                try photo.apply(aiResult(verdict, for: photo.id), analyzedAt: Date())
                if let burst {
                    photo.burstNumber = burst.number
                    photo.isBestOfBurst = index == burst.best
                }
                photos.append(photo)
            }
            try context.save()
            self.photos = photos
            // In the app the window groups the changes of one key press; here each change is a group.
            undoManager.groupsByEvent = false
            browser.setPhotos(photos.map(\.burstInput))
            sorter = ManualSorter(browser: browser, context: context, undoManager: undoManager)
        }

        /// One click on a photo, as one undo step. (With `groupsByEvent` off, registering an undo
        /// outside a group is refused by AppKit.)
        func change(_ command: SortingCommand, _ photoId: UUID) {
            undoManager.beginUndoGrouping()
            browser.selection = photoId
            sorter.apply(command, to: [photoId])
            undoManager.endUndoGrouping()
        }

        func change(_ command: SortingCommand, _ photo: Photo) {
            change(command, photo.id)
        }

        /// One key press on the selection, as one undo step.
        @discardableResult
        func press(_ command: SortingCommand, advance: Bool) -> Bool {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return sorter.applyToSelection(command, advance: advance)
        }

        /// `userVerdictRaw` as saved, read by a separate context, in the order of `photos`.
        func storedUserVerdicts() throws -> [String?] {
            let stored = try ModelContext(context.container).fetch(FetchDescriptor<Photo>())
            return photos.map { photo in stored.first { $0.id == photo.id }?.userVerdictRaw }
        }
    }
}

private func draft(_ name: String, second: Int = 0) -> PhotoDraft {
    PhotoDraft(
        file: PhotoFile(url: URL(filePath: "/tmp/\(name)"), relativePath: name, fileSize: 1_000),
        metadata: PhotoMetadata(
            captureDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(second)), pixelWidth: 6000, pixelHeight: 4000
        ),
        importedAt: Date()
    )
}

/// A verdict with one reason of the same severity, as the classifier gives it.
private func aiResult(_ verdict: CullingVerdict, for photoId: UUID) -> CullingResult {
    let kind: CullingReason.Kind = switch verdict {
    case .keep: .noIssue
    case .review, .unknown: .analysisFailed
    case .reject: .blurry
    }
    return CullingResult(photoId: photoId, verdict: verdict, reasons: [CullingReason(kind: kind, verdict: verdict)])
}

/// An indexed gallery whose files do not exist: enough for everything that does not read them.
private func galleryWithoutFiles(_ names: [String], store: LibraryStore) async throws -> UUID {
    let galleryId = try await store.createGallery(name: "Séance", folderPath: "/tmp/séance", folderBookmark: Data())
    try await store.insert(names.enumerated().map { draft($1, second: $0) }, galleryId: galleryId)
    try await store.finishIndexing(galleryId: galleryId)
    return galleryId
}
