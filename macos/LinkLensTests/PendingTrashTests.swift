import Foundation
import SwiftData
import Testing
@testable import LinkLens

// The pending trash: photos marked for the trash while their disk is unplugged (F9), offered to the trash
// once it is back. Temporary folders only, the trash is a `FolderTrash` (or one that refuses), the
// catalogue is in memory.

@MainActor
struct PendingTrashTests {
    private static let unplugged = GalleryAvailability.diskDisconnected(volumeName: "DATA")

    @Test func markingWhileUnpluggedTouchesNoFile() async throws {
        let setup = try await PhotoDeletionSetup.make(files: ["A.JPG", "B.JPG", "C.JPG"])
        defer { setup.remove() }
        let files = try setup.folder.snapshot()
        let ids = try setup.ids(["A.JPG", "B.JPG", "C.JPG"])
        setup.controller.galleryAvailability = { _ in Self.unplugged }
        // As when the disk is really away: the gallery's folder is not there at all.
        let away = setup.folder.url.deletingLastPathComponent().appending(path: "away-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: setup.folder.url, to: away)

        #expect(setup.controller.blockReason(galleryId: setup.galleryId) == nil, "« Supprimer… » stays enabled")
        #expect(setup.controller.pendingVolumeName(galleryId: setup.galleryId) == "DATA")
        setup.controller.requestDeletion(try setup.request([ids[0], ids[1]]), undoManager: setup.undoManager)
        let request = try #require(setup.controller.request)
        #expect(request.action == .markPending(volumeName: "DATA"))
        #expect(setup.controller.stamps == [:], "no file read")
        #expect(PhotoDeletionText.pendingTitle(count: request.count, kind: request.kind) == "Mettre 2 photos en attente de corbeille ?")
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        try FileManager.default.moveItem(at: away, to: setup.folder.url)
        #expect(setup.controller.request == nil, "the window closed")
        #expect(try setup.folder.snapshot() == files, "every file where it was, unchanged")
        #expect(try setup.trashFolder.snapshot().isEmpty)
        #expect(setup.controller.report == nil && setup.controller.banner == nil)
        let marked = try setup.catalogue()
        #expect(marked.count == 3, "nothing left the catalogue")
        #expect(marked.filter { $0.pendingTrashAt != nil }.map(\.relativePath) == ["A.JPG", "B.JPG"])
        #expect(setup.undoManager.undoActionName == "Mise en attente de corbeille de 2 photos")

        // Asking again: only the photo not marked yet is in the window.
        setup.controller.requestDeletion(try setup.request(ids), undoManager: setup.undoManager)
        #expect(setup.controller.request?.items.map(\.photoId) == [ids[2]])
        setup.controller.cancel()
        // Every photo already marked: no window at all.
        setup.controller.requestDeletion(try setup.request([ids[0]]), undoManager: setup.undoManager)
        #expect(setup.controller.request == nil)
    }

    @Test func undoAndRedoTheMarking() async throws {
        let setup = try await PhotoDeletionSetup.make(files: ["A.JPG", "B.JPG"])
        defer { setup.remove() }
        let ids = try setup.ids(["A.JPG", "B.JPG"])
        setup.controller.galleryAvailability = { _ in Self.unplugged }
        let before = try setup.catalogue()

        setup.controller.requestDeletion(try setup.request(ids), undoManager: setup.undoManager)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        let marked = try setup.catalogue()
        #expect(marked.allSatisfy { $0.pendingTrashAt != nil })

        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue() == before, "⌘Z: no longer marked")
        #expect(setup.undoManager.canRedo)

        setup.undoManager.redo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue() == marked, "⇧⌘Z: marked again, same date")

        // « Retirer de l'attente », then ⌘Z: the marks come back as they were.
        let photos = try ModelContext(setup.container).fetch(FetchDescriptor<Photo>())
        setup.controller.unmarkPending(photos, undoManager: setup.undoManager)
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue() == before)
        #expect(setup.undoManager.undoActionName == "Retrait de l'attente de 2 photos")
        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue() == marked)
    }

    @Test func theTrashIsOfferedOnlyOnceTheDiskIsBack() {
        let setup = PendingTrashOfferSetup()
        let controller = setup.controller
        var availability = Self.unplugged
        controller.galleryAvailability = { _ in availability }
        #expect(!controller.offersPendingTrash(galleryId: UUID(), pendingCount: 26), "disk unplugged: no offer")
        availability = .folderMissing
        #expect(!controller.offersPendingTrash(galleryId: UUID(), pendingCount: 26), "folder missing: no offer")
        #expect(controller.blockReason(galleryId: UUID()) != nil, "folder missing: no marking either")
        availability = .available
        #expect(!controller.offersPendingTrash(galleryId: UUID(), pendingCount: 0))
        #expect(controller.offersPendingTrash(galleryId: UUID(), pendingCount: 26))
        // An offer only: nothing opens or moves by itself.
        #expect(controller.request == nil && controller.progress == nil)
    }

    @Test func aChangedOrMissingFileIsSkippedListedAndStaysMarked() async throws {
        let setup = try await PhotoDeletionSetup.make(files: ["A.JPG", "B.JPG", "C.JPG"])
        defer { setup.remove() }
        let ids = try setup.ids(["A.JPG", "B.JPG", "C.JPG"])
        setup.controller.galleryAvailability = { _ in Self.unplugged }
        setup.controller.requestDeletion(try setup.request(ids), undoManager: setup.undoManager)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        // While the disk was away, B was edited elsewhere (another size) and C was deleted.
        let changed = setup.folder.url.appending(path: "B.JPG")
        try (try Data(contentsOf: changed) + Data("edited".utf8)).write(to: changed)
        try FileManager.default.removeItem(at: setup.folder.url.appending(path: "C.JPG"))
        let left = try setup.folder.snapshot()

        // The disk is back: the banner's « Mettre à la corbeille… ».
        setup.controller.galleryAvailability = { _ in .available }
        let photos = try ModelContext(setup.container).fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.relativePath)]))
        setup.controller.requestDeletion(
            PhotoDeletionRequest(galleryId: setup.galleryId, galleryName: "Test", kind: .pending, items: photos.filter(\.isPendingTrash).map(\.trashItem)),
            undoManager: setup.undoManager
        )
        await setup.controller.waitUntilIdle()
        #expect(setup.controller.request?.action == .moveToTrash)
        #expect(setup.controller.stamps?.count == 1, "C is missing and B changed: no stamp for either")
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try setup.folder.snapshot().keys.sorted() == ["B.JPG"])
        #expect(try setup.folder.snapshot()["B.JPG"] == left["B.JPG"], "the edited file is left untouched")
        #expect(try setup.trashFolder.snapshot().count == 1, "only A went to the trash")
        let report = try #require(setup.controller.report)
        #expect(report.skipped.map(\.item.relativePath) == ["B.JPG", "C.JPG"])
        #expect(report.skipped.map(\.reason) == [.changedSinceImport, .missing])
        #expect(report.keepsPendingMarks)
        let remaining = try setup.catalogue()
        #expect(remaining.map(\.relativePath) == ["B.JPG", "C.JPG"])
        #expect(remaining.allSatisfy { $0.pendingTrashAt != nil }, "still marked, until the user decides")
        #expect(setup.controller.banner?.kind == .trashed(count: 1, keptInPlace: 2))

        // ⌘Z puts A back, still marked.
        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        let restored = try #require(try setup.catalogue().first { $0.relativePath == "A.JPG" })
        #expect(restored.pendingTrashAt != nil)
    }

    @Test func aRefusedTrashKeepsTheMarkAndNeverDeletes() async throws {
        // The DATA disk is exFAT: its trash says no.
        let setup = try await PhotoDeletionSetup.make(files: ["A.JPG", "B.JPG"], trash: { _ in RefusingTrash() })
        defer { setup.remove() }
        let files = try setup.folder.snapshot()
        let ids = try setup.ids(["A.JPG", "B.JPG"])
        setup.controller.galleryAvailability = { _ in Self.unplugged }
        setup.controller.requestDeletion(try setup.request(ids), undoManager: setup.undoManager)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        let marked = try setup.catalogue()

        setup.controller.galleryAvailability = { _ in .available }
        let photos = try ModelContext(setup.container).fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.relativePath)]))
        setup.controller.requestDeletion(
            PhotoDeletionRequest(galleryId: setup.galleryId, galleryName: "Test", kind: .pending, items: photos.map(\.trashItem)),
            undoManager: setup.undoManager
        )
        await setup.controller.waitUntilIdle()
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try setup.folder.snapshot() == files, "never deleted for good instead")
        let report = try #require(setup.controller.report)
        #expect(report.trashWasRefused && report.keepsPendingMarks)
        #expect(try setup.catalogue() == marked, "still in LinkLens, still marked")

        // « Retirer seulement de LinkLens », then ⌘Z: back with their mark.
        setup.controller.removeSkippedFromLibrary()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue().isEmpty)
        #expect(try setup.folder.snapshot() == files)
        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()
        #expect(try setup.catalogue() == marked)
    }

    @Test func manualSortingAndGalleryUndoKeepTheMark() async throws {
        let setup = try await PhotoDeletionSetup.make(files: ["A.JPG", "B.JPG"])
        defer { setup.remove() }
        let ids = try setup.ids(["A.JPG", "B.JPG"])
        setup.controller.galleryAvailability = { _ in Self.unplugged }
        setup.controller.requestDeletion(try setup.request([ids[0]]), undoManager: setup.undoManager)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        // P / U / X never clear the mark: only « Retirer de l'attente » does.
        let context = ModelContext(setup.container)
        let sorter = ManualSorter(browser: nil, context: context)
        #expect(sorter.apply(.choose(.keep), to: [ids[0]]))
        let photo = try #require(try ModelContext(setup.container).fetch(FetchDescriptor<Photo>()).first { $0.id == ids[0] })
        #expect(photo.userVerdict == .keep)
        #expect(photo.isPendingTrash)

        // Deleting the gallery from LinkLens, then « Annuler »: the mark comes back with it.
        let snapshot = try await setup.store.removeGallery(id: setup.galleryId)
        #expect(snapshot.photos.first { $0.id == ids[0] }?.pendingTrashAt != nil)
        try await setup.store.restoreGallery(snapshot)
        let back = try ModelContext(setup.container).fetch(FetchDescriptor<Photo>())
        #expect(back.filter(\.isPendingTrash).map(\.id) == [ids[0]])
    }

    @Test func theStoreWritesByBatches() async throws {
        let setup = try await PhotoDeletionSetup.makeLarge(count: 1_200)
        defer { setup.remove() }
        let ids = try ModelContext(setup.container).fetch(FetchDescriptor<Photo>()).map(\.id)
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        try await setup.store.setPendingTrash(ids.map { PendingTrashChange(photoId: $0, pendingTrashAt: date) }, batchSize: 500)
        #expect(try ModelContext(setup.container).fetch(FetchDescriptor<Photo>()).allSatisfy { $0.pendingTrashAt == date })
        // A photo no longer in the catalogue is skipped.
        try await setup.store.setPendingTrash([PendingTrashChange(photoId: UUID(), pendingTrashAt: nil)])
    }

    @Test func frenchSentences() {
        #expect(PhotoDeletionText.pendingCount(1) == "1 photo en attente de corbeille")
        #expect(PhotoDeletionText.pendingCount(26) == "26 photos en attente de corbeille")
        #expect(PhotoDeletionText.trashMenuTitle(count: 1, pending: true) == "Mettre en attente de corbeille…")
        #expect(PhotoDeletionText.rejectedMenuTitle(count: 26, pending: true) == "Mettre les 26 photos rejetées en attente de corbeille…")
        #expect(PhotoDeletionText.title(count: 26, kind: .pending) == "Mettre les 26 photos en attente à la corbeille ?")
        #expect(PhotoDeletionText.pendingExplanation(volumeName: "DATA").contains("quand le disque « DATA » sera rebranché, après votre confirmation"))
        #expect(PhotoDeletionText.unmarkMenuTitle(count: 3) == "Retirer les 3 photos de l'attente de corbeille")
    }
}

/// A controller with an empty in-memory catalogue, for the decisions that read no photo.
@MainActor
private struct PendingTrashOfferSetup {
    let controller: PhotoDeletionController

    init() {
        // `try!`: an in-memory container only fails on a broken model, which every other test would show.
        let container = try! makeInMemoryContainer()
        controller = PhotoDeletionController(store: LibraryStore(modelContainer: container))
    }
}
