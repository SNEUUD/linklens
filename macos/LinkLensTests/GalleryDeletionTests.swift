import AppKit
import Foundation
import SwiftData
import Testing
@testable import LinkLens

// Deleting a gallery. Every folder put in the trash here is a `TestFolder` (a unique name in the
// temporary directory): the trash is the user's and shared by the tests running at the same time.
// Nothing outside the temporary directory is ever touched, and the catalogue is in memory.

// MARK: - Safeguards (pure rules)

struct FolderTrashRulesTests {
    private let home = "/Users/chris"
    private var protected: [String] { FolderTrashRules.protectedPaths(home: home, extra: ["/Users/chris/Pictures/LinkLens"]) }

    private func block(_ path: String, others: [FolderTrashRules.GalleryFolder] = [], isVolumeRoot: Bool = false) -> FolderTrashBlock? {
        FolderTrashRules.block(folderPath: path, isVolumeRoot: isVolumeRoot, otherGalleries: others, protectedPaths: protected)
    }

    @Test func aGalleryFolderOfItsOwnMayGo() {
        #expect(block("/Users/chris/Downloads/photos") == nil)
        #expect(block("/Users/chris/Pictures/LinkLens/2026/2026-09-20 Mariage") == nil)
        #expect(block("/Volumes/Photos 2TB/2026/2026-09-12 Mariage") == nil)
    }

    @Test(arguments: [
        "/", "/Users", "/Users/chris", "/Users/chris/Desktop", "/Users/chris/Downloads", "/Users/chris/Pictures",
        "/Users/chris/Documents", "/Users/chris/Movies", "/Applications", "/System", "/Library", "/Users/Shared",
        "/Users/chris/Library/Mobile Documents/com~apple~CloudDocs",
        // The default import location: it holds every year folder of the card imports.
        "/Users/chris/Pictures/LinkLens",
    ])
    func systemFoldersNeverGo(path: String) {
        #expect(block(path) == .protectedLocation(name: (path as NSString).lastPathComponent))
    }

    @Test func spellingDoesNotGetAroundTheRules() {
        // The Mac's disk ignores case; a trailing slash or « .. » names the same folder.
        #expect(block("/users/CHRIS/downloads/") == .protectedLocation(name: "downloads"))
        #expect(block("/Users/chris/Downloads/photos/..") != nil)
        // « Forêt » with its accent stored apart (decomposed) is the same folder as « Forêt ».
        let decomposed = "/Users/chris/Pictures/Fore\u{0302}t"
        let others = [FolderTrashRules.GalleryFolder(name: "Forêt", path: "/Users/chris/Pictures/For\u{00EA}t/Jour 1")]
        #expect(block(decomposed, others: others) == .containsGallery(name: "Forêt"))
    }

    @Test func aWholeDiskNeverGoes() {
        #expect(block("/Volumes/Photos 2TB") == .volumeRoot(name: "Photos 2TB"))
        #expect(block("/Volumes/SDTEST/") == .volumeRoot(name: "SDTEST"))
        // A disk mounted elsewhere, recognised from the disk itself.
        #expect(block("/Users/chris/Mounts/Archive", isVolumeRoot: true) == .volumeRoot(name: "Archive"))
    }

    @Test func neverTakesAnotherGalleryAlong() {
        let wedding = FolderTrashRules.GalleryFolder(name: "Mariage", path: "/Volumes/Photos 2TB/2026/2026-09-12 Mariage")
        // The folder holds another gallery's folder.
        #expect(block("/Volumes/Photos 2TB/2026", others: [wedding]) == .containsGallery(name: "Mariage"))
        // The folder is inside another gallery's folder.
        #expect(block("/Volumes/Photos 2TB/2026/2026-09-12 Mariage/Cérémonie", others: [wedding]) == .insideGallery(name: "Mariage"))
        // The very same folder indexed twice.
        #expect(block("/Volumes/Photos 2TB/2026/2026-09-12 Mariage", others: [wedding]) == .containsGallery(name: "Mariage"))
        // Same beginning of name is not « inside »: « Mariage 2 » is a folder of its own.
        #expect(block("/Volumes/Photos 2TB/2026/2026-09-12 Mariage 2", others: [wedding]) == nil)
    }

    @Test func aCardImportOnlyEverTrashesItsSessionFolder() {
        // F1 layout: <location>/2026/2026-09-20 Séance/. The gallery's folder is the session folder;
        // the year folder holds the other sessions of the year, the location holds every year.
        let other = FolderTrashRules.GalleryFolder(name: "Balade", path: "/Users/chris/Pictures/LinkLens/2026/2026-09-27 Balade")
        #expect(block("/Users/chris/Pictures/LinkLens/2026/2026-09-20 Séance", others: [other]) == nil)
        #expect(block("/Users/chris/Pictures/LinkLens/2026", others: [other]) == .containsGallery(name: "Balade"))
        #expect(block("/Users/chris/Pictures/LinkLens", others: [other]) == .protectedLocation(name: "LinkLens"))
    }

    @Test func everyBlockSaysWhyInPlainWords() {
        let blocks: [FolderTrashBlock] = [
            .diskDisconnected(volumeName: "Photos 2TB"), .folderMissing, .containsGallery(name: "Mariage"),
            .insideGallery(name: "Mariage"), .protectedLocation(name: "Downloads"), .volumeRoot(name: "Photos 2TB"),
            .unreadable, .folderMoved,
        ]
        for block in blocks {
            #expect(!block.message.isEmpty)
        }
        #expect(FolderTrashBlock.diskDisconnected(volumeName: "Photos 2TB").message.contains("« Photos 2TB »"))
        #expect(FolderTrashBlock.containsGallery(name: "Mariage").message.contains("« Mariage »"))
    }
}

// MARK: - Wording

struct GalleryDeletionTextTests {
    private let french = Locale(identifier: "fr_FR")

    @Test func folderSummaryInFrench() {
        let contents = FolderContents(entries: (0..<52).map {
            FolderContents.Entry(relativePath: "DSC\($0).ARW", size: 1_200_000_000 / 52, modifiedAt: nil)
        })
        // French puts a non-breaking space before the unit: written as a plain space here.
        #expect(plainSpaces(contents.summary(locale: french)) == "52 fichiers · 1,2 Go")
        let one = FolderContents(entries: [FolderContents.Entry(relativePath: "a.jpg", size: 2_500_000, modifiedAt: nil)])
        #expect(plainSpaces(one.summary(locale: french)) == "1 fichier · 2,5 Mo")
    }

    @Test func photoAndVideoCounts() {
        #expect(GalleryDeletionText.contents(photoCount: 52, videoCount: 0, locale: french) == "52 photos")
        #expect(GalleryDeletionText.contents(photoCount: 52, videoCount: 1, locale: french) == "52 photos et 1 vidéo")
        #expect(GalleryDeletionText.contents(photoCount: 1, videoCount: 3, locale: french) == "1 photo et 3 vidéos")
        #expect(GalleryDeletionText.contents(photoCount: 0, videoCount: 2, locale: french) == "2 vidéos")
    }

    @Test func voiceOverReadsTheFolderAndItsSize() {
        let contents = FolderContents(entries: [FolderContents.Entry(relativePath: "a.jpg", size: 2_500_000, modifiedAt: nil)])
        let label = GalleryDeletionText.checkboxLabel(path: "~/Downloads/photos", contents: contents, locale: french)
        #expect(plainSpaces(label) == "Mettre aussi le dossier à la corbeille. ~/Downloads/photos. 1 fichier · 2,5 Mo")
    }

    @Test func showsTheNextGalleryAfterADeletion() {
        let now = Date()
        func location(_ name: String, age: Double) -> GalleryLocation {
            GalleryLocation(id: UUID(), name: name, folderPath: "/\(name)", createdAt: now - age, folderBookmark: Data())
        }
        let (newest, middle, oldest) = (location("a", age: 0), location("b", age: 10), location("c", age: 20))
        let all = [oldest, newest, middle]
        #expect(GalleryDeletionController.neighbour(of: newest.id, in: all) == middle.id)
        #expect(GalleryDeletionController.neighbour(of: oldest.id, in: all) == middle.id)
        #expect(GalleryDeletionController.neighbour(of: newest.id, in: [newest]) == nil)
    }
}

// MARK: - Folder to the trash and back

struct GalleryFolderTrasherTests {
    @Test func movesTheFolderToTheTrashAndPutsItBack() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        try folder.writeFile("Jour 2/DSC2.ARW", contents: "raw")
        let before = try folder.snapshot()
        let path = FolderBookmark.canonicalPath(of: folder.url)

        let trashed = try await GalleryFolderTrasher.moveToTrash(folder.url, expectedPath: path, otherGalleries: [], protectedPaths: [])

        let trashURL = try #require(trashed.trashURL)
        defer { try? FileManager.default.removeItem(at: trashURL) } // only if the test failed before the undo
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
        #expect(trashURL.pathComponents.contains(".Trash"), "got \(trashURL.path)")
        #expect(trashed.contents.fileCount == 2)

        #expect(await GalleryFolderTrasher.restore(trashed) == nil)
        #expect(try folder.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
    }

    @Test func neverPutsTheFolderBackOverSomethingElse() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeFile("DSC1.ARW", contents: "raw")
        let trashed = try await GalleryFolderTrasher.moveToTrash(
            folder.url, expectedPath: FolderBookmark.canonicalPath(of: folder.url), otherGalleries: [], protectedPaths: []
        )
        let trashURL = try #require(trashed.trashURL)
        defer { try? FileManager.default.removeItem(at: trashURL) } // the test's own folder, left in the trash
        // A new folder with the same name, at the same place.
        try folder.writeFile("Nouveau.txt", contents: "someone else's")
        let newcomer = try folder.snapshot()

        #expect(await GalleryFolderTrasher.restore(trashed) == .placeTaken)
        #expect(try folder.snapshot() == newcomer, "the new folder is left alone")
        #expect(FileManager.default.fileExists(atPath: trashURL.path), "the old one stays in the trash")
    }

    @Test func leavesAFolderThatChangedInTheTrash() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeFile("DSC1.ARW", contents: "raw")
        let trashed = try await GalleryFolderTrasher.moveToTrash(
            folder.url, expectedPath: FolderBookmark.canonicalPath(of: folder.url), otherGalleries: [], protectedPaths: []
        )
        let trashURL = try #require(trashed.trashURL)
        defer { try? FileManager.default.removeItem(at: trashURL) }
        // Not the same folder any more (the trash was emptied and another one put there, or it was edited).
        try Data("other".utf8).write(to: trashURL.appending(path: "Autre.ARW"))

        #expect(await GalleryFolderTrasher.restore(trashed) == .notInTrash)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func checksEverythingAgainRightBeforeTheMove() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeFile("DSC1.ARW", contents: "raw")
        let path = FolderBookmark.canonicalPath(of: folder.url)
        let before = try folder.snapshot()

        // Another gallery appeared inside, the folder became protected, or it moved: nothing happens.
        let nested = [FolderTrashRules.GalleryFolder(name: "Dedans", path: path + "/Jour 2")]
        await #expect(throws: GalleryDeletionError.folderBlocked(.containsGallery(name: "Dedans"))) {
            try await GalleryFolderTrasher.moveToTrash(folder.url, expectedPath: path, otherGalleries: nested, protectedPaths: [])
        }
        await #expect(throws: GalleryDeletionError.folderBlocked(.protectedLocation(name: folder.url.lastPathComponent))) {
            try await GalleryFolderTrasher.moveToTrash(folder.url, expectedPath: path, otherGalleries: [], protectedPaths: [path])
        }
        await #expect(throws: GalleryDeletionError.folderBlocked(.folderMoved)) {
            try await GalleryFolderTrasher.moveToTrash(folder.url, expectedPath: path + " ailleurs", otherGalleries: [], protectedPaths: [])
        }
        #expect(try folder.snapshot() == before)
    }
}

// MARK: - Catalogue

struct GalleryRemovalStoreTests {
    @Test func removesAndRestoresTheGalleryExactly() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        for index in 1...4 {
            try folder.writeJPEG("DSC\(index).JPG", exifDate: "2026:09:20 14:40:0\(index)")
        }
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await indexTestGallery(folder, store: store)
        let before = try await sortLikeAUser(galleryId: galleryId, container: container, store: store)

        let snapshot = try await store.removeGallery(id: galleryId)

        var context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Gallery>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Photo>()).isEmpty, "the photos and choices go with the gallery")
        #expect(snapshot.sorted == before)

        try await store.restoreGallery(snapshot)
        try await store.restoreGallery(snapshot) // a second undo changes nothing

        context = ModelContext(container)
        let galleries = try context.fetch(FetchDescriptor<Gallery>())
        #expect(galleries.count == 1)
        #expect(try #require(galleries.first).snapshot.sorted == before)
        #expect(try context.fetch(FetchDescriptor<Photo>()).count == 4)
    }
}

// MARK: - The whole deletion, with undo

@MainActor
struct GalleryDeletionControllerTests {
    /// Everything a test needs, with its own catalogue, thumbnail cache and purge file.
    private struct Setup {
        let container: ModelContainer
        let store: LibraryStore
        let cache: ThumbnailCache
        let queue: ThumbnailPurgeQueue
        let controller: GalleryDeletionController
        let undoManager: UndoManager
        let selection: SelectionBox

        func remove() {
            try? FileManager.default.removeItem(at: cache.directory)
        }
    }

    @MainActor
    final class SelectionBox {
        var galleryId: UUID?
    }

    private func makeSetup(
        undoPeriod: Duration = .seconds(600),
        writeAccess: @escaping @MainActor (GalleryLocation) -> URL? = { URL(filePath: $0.folderPath, directoryHint: .isDirectory) }
    ) throws -> Setup {
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let cache = ThumbnailCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "LinkLensDeletionThumbnails-\(UUID().uuidString)", directoryHint: .isDirectory))
        let queue = ThumbnailPurgeQueue(fileURL: cache.directory.appending(path: "Pending.json"))
        let controller = GalleryDeletionController(
            store: store, cache: cache, purgeQueue: queue, undoPeriod: undoPeriod, bannerDuration: .seconds(600),
            requestWriteAccess: writeAccess
        )
        // The test folders are in the app's container, under ~/Library: only the system folders are protected.
        controller.protectedPaths = { FolderTrashRules.protectedPaths(home: realHomeDirectory()) }
        let selection = SelectionBox()
        controller.selectedGalleryId = { selection.galleryId }
        controller.selectGallery = { selection.galleryId = $0 }
        let undoManager = UndoManager()
        // As in the app's other undo tests: no automatic grouping by event in a test.
        undoManager.groupsByEvent = false
        return Setup(container: container, store: store, cache: cache, queue: queue, controller: controller, undoManager: undoManager, selection: selection)
    }

    private func request(_ galleryId: UUID, in setup: Setup) throws -> GalleryDeletionRequest {
        let context = ModelContext(setup.container)
        let gallery = try #require(try context.fetch(FetchDescriptor<Gallery>()).first { $0.id == galleryId })
        return GalleryDeletionRequest(gallery)
    }

    /// Opens the window and waits until the folder has been looked at.
    private func open(_ galleryId: UUID, in setup: Setup) async throws {
        setup.controller.requestDeletion(try request(galleryId, in: setup), undoManager: setup.undoManager)
        await setup.controller.waitUntilIdle()
        #expect(setup.controller.request?.galleryId == galleryId)
        #expect(setup.controller.alsoTrashFolder == false, "unticked by default")
    }

    private func addThumbnails(for galleryId: UUID, in setup: Setup) throws -> [UUID] {
        let ids = try ModelContext(setup.container).fetch(FetchDescriptor<Photo>()).filter { $0.gallery?.id == galleryId }.map(\.id)
        try FileManager.default.createDirectory(at: setup.cache.directory, withIntermediateDirectories: true)
        for id in ids {
            try Data("jpeg".utf8).write(to: setup.cache.fileURL(for: id))
        }
        return ids
    }

    private func galleryIds(in setup: Setup) throws -> [UUID] {
        try ModelContext(setup.container).fetch(FetchDescriptor<Gallery>()).map(\.id)
    }

    @Test func deletesFromTheCatalogueAndUndoesWithCommandZ() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        for index in 1...3 { try folder.writeJPEG("DSC\(index).JPG", exifDate: "2026:09:20 14:40:0\(index)") }
        let setup = try makeSetup()
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)
        let before = try await sortLikeAUser(galleryId: galleryId, container: setup.container, store: setup.store)
        let thumbnails = try addThumbnails(for: galleryId, in: setup)
        let files = try folder.snapshot()
        setup.selection.galleryId = galleryId

        try await open(galleryId, in: setup)
        #expect(setup.controller.folderCheck?.contents?.fileCount == 3)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try galleryIds(in: setup).isEmpty)
        #expect(setup.controller.request == nil, "the window closed")
        #expect(setup.controller.banner?.kind == .deleted(folderTrashed: false))
        #expect(setup.selection.galleryId == nil)
        #expect(try folder.snapshot() == files, "the folder was not touched")
        // The thumbnails stay while « Annuler » is possible.
        #expect(thumbnails.allSatisfy(setup.cache.contains))
        #expect(setup.queue.pending()[galleryId]?.count == 3)
        #expect(setup.undoManager.canUndo)
        #expect(setup.undoManager.undoActionName == "Suppression de « \(folder.url.lastPathComponent) »")

        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()

        let restored = try #require(try ModelContext(setup.container).fetch(FetchDescriptor<Gallery>()).first)
        #expect(restored.snapshot.sorted == before, "same ids, choices, verdicts, bursts and best photos")
        #expect(thumbnails.allSatisfy(setup.cache.contains), "same thumbnails, so the same cover")
        #expect(setup.queue.pending().isEmpty)
        #expect(setup.selection.galleryId == galleryId)
        #expect(setup.controller.banner?.kind == .restored(problem: nil))
        #expect(!setup.controller.canUndo(galleryId: galleryId))
    }

    @Test func cleansTheThumbnailsOnlyAtTheEndOfTheUndoPeriod() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        try folder.writeJPEG("DSC2.JPG")
        let setup = try makeSetup(undoPeriod: .milliseconds(300))
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)
        let thumbnails = try addThumbnails(for: galleryId, in: setup)

        try await open(galleryId, in: setup)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        #expect(try galleryIds(in: setup).isEmpty)
        #expect(thumbnails.allSatisfy(setup.cache.contains), "still there right after the deletion")

        // Waits for the end of the period (a little more than 300 ms).
        for _ in 0..<40 where setup.controller.canUndo(galleryId: galleryId) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(!setup.controller.canUndo(galleryId: galleryId))
        #expect(!thumbnails.contains(where: setup.cache.contains), "gone once the undo is no longer possible")
        #expect(setup.queue.pending().isEmpty)
        #expect(!setup.undoManager.canUndo, "⌘Z no longer offers it")
        #expect(setup.controller.banner == nil)
    }

    @Test func trashesTheFolderWhenTickedAndPutsItBack() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        try folder.writeFile("Notes.txt", contents: "the folder's other files go with it")
        let files = try folder.snapshot()
        let setup = try makeSetup()
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)

        try await open(galleryId, in: setup)
        #expect(setup.controller.folderCheck?.contents?.fileCount == 2)
        setup.controller.alsoTrashFolder = true
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try galleryIds(in: setup).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path), "in the trash")
        #expect(setup.controller.banner?.kind == .deleted(folderTrashed: true))

        // The banner's « Annuler ».
        setup.controller.undo(galleryId: galleryId)
        await setup.controller.waitUntilIdle()

        #expect(try folder.snapshot() == files, "back at its place, unchanged")
        #expect(try galleryIds(in: setup) == [galleryId])
        #expect(!setup.undoManager.canUndo, "undone once, not twice")
    }

    @Test func undoBringsTheGalleryBackEvenIfTheFolderCannotBePutBack() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        let setup = try makeSetup()
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)
        try await open(galleryId, in: setup)
        setup.controller.alsoTrashFolder = true
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        let trashURL = try #require(setup.controller.trashedFolder(of: galleryId)?.trashURL)
        defer { try? FileManager.default.removeItem(at: trashURL) } // the test's own folder, left in the trash
        try folder.writeFile("Autre.txt", contents: "a new folder with the same name")

        setup.undoManager.undo()
        await setup.controller.waitUntilIdle()

        #expect(try galleryIds(in: setup) == [galleryId], "the choices are not lost")
        #expect(setup.controller.banner?.kind == .restored(problem: FolderRestoreProblem.placeTaken.message))
        #expect(FileManager.default.fileExists(atPath: trashURL.path))
        #expect(try folder.snapshot().keys.sorted() == ["Autre.txt"])
    }

    @Test func diskUnpluggedOrFolderMissingGreysTheBoxOut() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        let setup = try makeSetup()
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)
        let files = try folder.snapshot()

        setup.controller.galleryAvailability = { _ in .diskDisconnected(volumeName: "Photos 2TB") }
        try await open(galleryId, in: setup)
        #expect(setup.controller.folderCheck?.block == .diskDisconnected(volumeName: "Photos 2TB"))
        // Even if the box were ticked somehow, the folder stays: only the gallery goes.
        setup.controller.alsoTrashFolder = true
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        #expect(try galleryIds(in: setup).isEmpty)
        #expect(try folder.snapshot() == files)

        // F9's other case, seen from the folder itself.
        let location = GalleryLocation(id: UUID(), name: "Absent", folderPath: folder.url.path + "-absent", createdAt: .now,
                                       folderBookmark: try FolderBookmark.create(for: folder.url))
        folder.remove()
        let check = await GalleryFolderTrasher.inspect(location, availability: .available, otherGalleries: [], protectedPaths: [])
        #expect(check.block == .folderMissing)
    }

    @Test func nestedGalleriesGreyTheBoxOut() async throws {
        let outer = try TestFolder()
        defer { outer.remove() }
        try outer.writeJPEG("DSC1.JPG")
        try outer.writeJPEG("Jour 2/DSC2.JPG")
        let inner = outer.url.appending(path: "Jour 2", directoryHint: .isDirectory)
        let setup = try makeSetup()
        defer { setup.remove() }
        let outerId = try await indexTestGallery(outer, store: setup.store)
        let innerId = try await FolderIndexer(store: setup.store).indexFolder(at: inner).galleryId

        try await open(outerId, in: setup)
        #expect(setup.controller.folderCheck?.block == .containsGallery(name: "Jour 2"))
        setup.controller.cancel()
        try await open(innerId, in: setup)
        #expect(setup.controller.folderCheck?.block == .insideGallery(name: outer.url.lastPathComponent))
        setup.controller.cancel()
        #expect(try galleryIds(in: setup).count == 2, "« Annuler » changes nothing")
    }

    @Test func aSystemFolderGreysTheBoxOutAndIsCheckedAgainOnConfirm() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        let setup = try makeSetup()
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)
        let path = FolderBookmark.canonicalPath(of: folder.url)
        let files = try folder.snapshot()

        setup.controller.protectedPaths = { [path] }
        try await open(galleryId, in: setup)
        #expect(setup.controller.folderCheck?.block == .protectedLocation(name: folder.url.lastPathComponent))
        setup.controller.cancel()

        // Allowed when the window opens, protected by the time « Supprimer » is clicked: nothing is deleted.
        setup.controller.protectedPaths = { [] }
        try await open(galleryId, in: setup)
        #expect(setup.controller.folderCheck?.isAllowed == true)
        setup.controller.alsoTrashFolder = true
        setup.controller.protectedPaths = { [path] }
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(try galleryIds(in: setup) == [galleryId])
        #expect(try folder.snapshot() == files)
        #expect(setup.controller.request != nil, "the window stays open with the reason")
        #expect(setup.controller.errorMessage?.contains("Rien n'a été supprimé") == true)
        #expect(setup.controller.folderCheck?.block == .protectedLocation(name: folder.url.lastPathComponent))
        #expect(setup.controller.alsoTrashFolder == false)
    }

    @Test func aCardImportTrashesItsSessionFolderButNeverTheYearFolder() async throws {
        let (card, destination) = try (TestFolder(), TestFolder())
        defer { card.remove(); destination.remove() }
        try card.writeJPEG("DCIM/100MSDCF/DSC00001.JPG", exifDate: "2026:10:14 10:00:00")
        let setup = try makeSetup(writeAccess: { _ in nil }) // F1 saved its read-write permission: no panel
        defer { setup.remove() }
        let contents = try CardScanner.scan(card: card.url)
        let date = try #require(contents.earliestDate)
        let importer = CardImporter(store: setup.store)
        let first = try await importer.importCard(CardImportRequest(card: contents, destination: destination.url, sessionName: "Séance", sessionDate: date))
        let second = try await importer.importCard(CardImportRequest(card: contents, destination: destination.url, sessionName: "Balade", sessionDate: date))
        let firstId = try #require(first.galleryId)
        let yearFolder = first.sessionFolder.deletingLastPathComponent()
        #expect(yearFolder.lastPathComponent == "2026")
        let secondFiles = try TestFolder.snapshot(of: second.sessionFolder)

        try await open(firstId, in: setup)
        #expect(setup.controller.folderCheck?.folderPath == FolderBookmark.canonicalPath(of: first.sessionFolder))
        setup.controller.alsoTrashFolder = true
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        let trashURL = try #require(setup.controller.trashedFolder(of: firstId)?.trashURL)
        defer { try? FileManager.default.removeItem(at: trashURL) } // the test's own folder, left in the trash

        #expect(!FileManager.default.fileExists(atPath: first.sessionFolder.path), "the session folder is in the trash")
        #expect(FileManager.default.fileExists(atPath: yearFolder.path), "the year folder stays")
        #expect(try TestFolder.snapshot(of: second.sessionFolder) == secondFiles, "the other session is untouched")
        #expect(trashURL.lastPathComponent.hasSuffix("Séance"))
    }

    @Test func refusingTheAuthorisationChangesNothing() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        let asked = SelectionBox()
        let setup = try makeSetup(writeAccess: { gallery in
            asked.galleryId = gallery.id
            return nil // « Annuler » in the « Autoriser » panel
        })
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)
        let files = try folder.snapshot()

        try await open(galleryId, in: setup)
        setup.controller.alsoTrashFolder = true
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()

        #expect(asked.galleryId == galleryId, "a folder only indexed (F2) asks for the permission, as F5 does")
        #expect(try galleryIds(in: setup) == [galleryId])
        #expect(try folder.snapshot() == files)
        #expect(setup.controller.request != nil)
    }

    @Test func leftoverThumbnailsGoAtTheNextLaunchOrWhenQuitting() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC1.JPG")
        let setup = try makeSetup()
        defer { setup.remove() }
        let galleryId = try await indexTestGallery(folder, store: setup.store)
        let kept = try addThumbnails(for: galleryId, in: setup)
        // A gallery deleted before a crash: its photos are no longer in the catalogue.
        let gone = [UUID(), UUID()]
        for id in gone { try Data("jpeg".utf8).write(to: setup.cache.fileURL(for: id)) }
        setup.queue.add(galleryId: UUID(), photoIds: gone)
        // A queue entry whose photos are back in the catalogue (crash during an undo).
        setup.queue.add(galleryId: galleryId, photoIds: kept)

        await setup.controller.purgeLeftovers()

        #expect(!gone.contains(where: setup.cache.contains))
        #expect(kept.allSatisfy(setup.cache.contains), "never the thumbnail of a photo in the catalogue")
        #expect(setup.queue.pending().isEmpty)

        // When quitting: the undo ends now.
        try await open(galleryId, in: setup)
        setup.controller.confirm()
        await setup.controller.waitUntilIdle()
        setup.controller.finishAllNow()
        #expect(!kept.contains(where: setup.cache.contains))
        #expect(setup.queue.pending().isEmpty)
    }
}

// MARK: - Helpers

/// Non-breaking spaces (as the French number formats write them) turned into plain ones.
private func plainSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}

private func indexTestGallery(_ folder: TestFolder, store: LibraryStore) async throws -> UUID {
    try await FolderIndexer(store: store).indexFolder(at: folder.url).galleryId
}

extension IndexingResult {
    fileprivate var galleryId: UUID {
        switch self {
        case .indexed(let galleryId, _), .alreadyIndexed(let galleryId): galleryId
        }
    }
}

extension TestFolder {
    /// The same listing as `snapshot()`, for a folder created by the code under test.
    fileprivate static func snapshot(of url: URL) throws -> [String: FileFingerprint] {
        try TestFolder(existing: url).snapshot()
    }
}

extension GallerySnapshot {
    /// Photos in a fixed order, so two snapshots of the same gallery compare equal.
    fileprivate var sorted: GallerySnapshot {
        var copy = self
        copy.photos.sort { $0.id.uuidString < $1.id.uuidString }
        return copy
    }
}

/// AI verdicts with reasons, a burst with its best photo, choices of the user: what an undo must keep.
@MainActor
private func sortLikeAUser(galleryId: UUID, container: ModelContainer, store: LibraryStore) async throws -> GallerySnapshot {
    let ids = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        .filter { $0.gallery?.id == galleryId }
        .sorted { $0.relativePath < $1.relativePath }
        .map(\.id)
    try #require(ids.count >= 3)
    try await store.saveCulling([
        CullingResult(photoId: ids[0], verdict: .keep, reasons: [], burstNumber: 1, isBestOfBurst: true, sharpness: 0.9, aesthetics: 0.8),
        CullingResult(photoId: ids[1], verdict: .reject, reasons: [CullingReason(kind: .blurry, verdict: .reject, value: 0.1, threshold: 0.3, onSubject: true)], burstNumber: 1, isBestOfBurst: false, sharpness: 0.1, aesthetics: 0.2),
        CullingResult(photoId: ids[2], verdict: .review, reasons: [], sharpness: 0.5, aesthetics: 0.4),
    ], analyzedAt: Date(timeIntervalSince1970: 1_789_908_100))
    try await store.finishCulling(galleryId: galleryId)
    let context = ModelContext(container)
    let photos = try context.fetch(FetchDescriptor<Photo>()).filter { ids.contains($0.id) }
    for photo in photos {
        if photo.id == ids[1] {
            photo.userVerdictRaw = "keep"
            photo.bestOfBurstChosenAt = Date(timeIntervalSince1970: 1_789_908_200)
        }
        if photo.id == ids[2] { photo.userVerdictRaw = "reject" }
    }
    try context.save()
    let gallery = try #require(try ModelContext(container).fetch(FetchDescriptor<Gallery>()).first { $0.id == galleryId })
    return gallery.snapshot.sorted
}
