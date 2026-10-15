import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// F5: exact duplicates, the copy proposed to keep, the trash and "Annuler".
/// Every file used here is created in a temporary folder by the test itself.
struct DuplicateFinderTests {
    private let galleryA = UUID()
    private let galleryB = UUID()
    private let older = Date(timeIntervalSince1970: 1_780_000_000)
    private let newer = Date(timeIntervalSince1970: 1_790_000_000)

    private func copy(
        _ path: String, size: Int64, sha: String?, newerGallery: Bool = false, verdict: CullingVerdict? = nil
    ) -> DuplicateCopy {
        DuplicateCopy(
            photoId: UUID(), galleryId: newerGallery ? galleryB : galleryA,
            galleryName: newerGallery ? "Séance (2)" : "Séance", galleryCreatedAt: newerGallery ? newer : older,
            relativePath: path, fileSize: size, sha256: sha, verdict: verdict
        )
    }

    @Test func onlyFilesSharingASizeAreFingerprinted() {
        let unique = copy("unique.ARW", size: 300, sha: nil)
        let twinA = copy("a.ARW", size: 200, sha: nil)
        let twinB = copy("b.ARW", size: 200, sha: nil, newerGallery: true)
        let known = copy("c.ARW", size: 200, sha: "known")
        let emptyA = copy("empty-a.ARW", size: 0, sha: nil)
        let emptyB = copy("empty-b.ARW", size: 0, sha: nil)

        let toRead = DuplicateFinder.filesToFingerprint([unique, twinA, twinB, known, emptyA, emptyB])

        #expect(toRead.map(\.relativePath) == ["a.ARW", "b.ARW"], "unique size, known fingerprint and empty files are skipped")
    }

    @Test func groupsIdenticalFilesBiggestSavingFirst() {
        let small1 = copy("small.JPG", size: 10, sha: "s")
        let small2 = copy("small (2).JPG", size: 10, sha: "s")
        let big1 = copy("big.ARW", size: 1_000, sha: "b")
        let big2 = copy("big.ARW", size: 1_000, sha: "b", newerGallery: true)
        let big3 = copy("big (2).ARW", size: 1_000, sha: "b", newerGallery: true)
        let sameSizeOtherContent = copy("other.ARW", size: 1_000, sha: "o")
        let notHashed = copy("pending.ARW", size: 1_000, sha: nil)

        let groups = DuplicateFinder.groups([small1, big1, small2, big2, sameSizeOtherContent, big3, notHashed])

        #expect(groups.map(\.sha256) == ["b", "s"])
        #expect(groups[0].copies.map(\.photoId) == [big1.photoId, big2.photoId, big3.photoId], "oldest gallery first")
        #expect(groups[0].extraBytes == 2_000)
        #expect(groups[1].extraBytes == 10)
        #expect(DuplicateFinder.recoverableBytes(groups) == 2_010)
        #expect(DuplicateFinder.groups([small1, big1]).isEmpty)
    }

    @Test func proposesTheCopySortedKeepFirst() {
        let rejected = copy("DSC1.ARW", size: 5, sha: "x", verdict: .reject)
        let kept = copy("DSC1.ARW", size: 5, sha: "x", newerGallery: true, verdict: .keep)

        #expect(DuplicateFinder.proposal(for: [rejected, kept]) == KeepProposal(photoId: kept.photoId, reason: .sortedKeep))
    }

    @Test func otherwiseProposesTheOldestGallery() {
        let original = copy("DSC1 (2).ARW", size: 5, sha: "x", verdict: .keep)
        let reimported = copy("DSC1.ARW", size: 5, sha: "x", newerGallery: true, verdict: .keep)

        #expect(DuplicateFinder.proposal(for: [reimported, original]) == KeepProposal(photoId: original.photoId, reason: .oldestGallery))
    }

    @Test func otherwiseProposesTheSimplestName() {
        let numbered = copy("DSC1 (2).ARW", size: 5, sha: "x")
        let plain = copy("DSC1.ARW", size: 5, sha: "x")
        let nested = copy("Jour 2/DSC1.ARW", size: 5, sha: "x")

        #expect(DuplicateFinder.proposal(for: [numbered, nested, plain]) == KeepProposal(photoId: plain.photoId, reason: .simplestName))
    }

    @Test func recoverableSpaceIsWrittenInFrench() {
        let bytes: Int64 = 1_234_567_890
        let text = bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "fr_FR")))
        #expect(text.contains("Go") && text.contains(","), "got \(text)")
    }
}

struct DuplicateScannerTests {
    @Test func findsDuplicatesAcrossGalleriesReadingOnlyWhatIsNeeded() async throws {
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile("DSC1.ARW", contents: "same picture")
        try first.writeFile("DSC2.ARW", contents: "some picture")       // same size as DSC1, other content
        try first.writeFile("unique.ARW", contents: "a size nobody else has")
        try second.writeFile("DSC1.ARW", contents: "same picture")
        try second.writeFile("Jour 2/DSC1 (2).ARW", contents: "same picture")
        let before = (try first.snapshot(), try second.snapshot())

        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let firstId = try await indexGallery(first, store: store)
        let secondId = try await indexGallery(second, store: store)
        let recorder = ScanProgressRecorder()

        let report = try await DuplicateScanner(store: store, concurrency: 2, batchSize: 2).scan { progress in
            recorder.values.append(progress)
        }

        #expect(report.groups.count == 1)
        let group = try #require(report.groups.first)
        #expect(group.copies.map(\.galleryId) == [firstId, secondId, secondId])
        #expect(group.proposal.reason == .oldestGallery)
        #expect(group.copies.first { $0.photoId == group.proposal.photoId }?.galleryId == firstId)
        #expect(report.recoverableBytes == 2 * Int64("same picture".utf8.count))
        #expect(report.unreachableGalleries.isEmpty && report.unreadableFiles == 0)

        // 4 files share the size of "same picture": read; the unique size is never read.
        let progress = await recorder.values
        #expect(progress.last?.completedFiles == 4 && progress.last?.totalFiles == 4)
        let photos = try ModelContext(container).fetch(FetchDescriptor<Photo>())
        #expect(photos.first { $0.relativePath == "unique.ARW" }?.sha256 == nil)
        #expect(photos.filter { $0.sha256 != nil }.count == 4)

        // Searching never changes a photo folder.
        #expect(try first.snapshot() == before.0)
        #expect(try second.snapshot() == before.1)

        // A second search reuses the saved fingerprints: nothing to read.
        await MainActor.run { recorder.values.removeAll() }
        let again = try await DuplicateScanner(store: store).scan { recorder.values.append($0) }
        #expect(again.groups == report.groups)
        #expect(await recorder.values.last?.totalFiles == 0)
    }

    @Test func listsGalleriesItCannotReach() async throws {
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile("DSC1.ARW", contents: "same picture")
        try second.writeFile("DSC1.ARW", contents: "same picture")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        _ = try await indexGallery(first, store: store)
        _ = try await indexGallery(second, store: store)
        second.remove() // like an unplugged disk (F9)

        let report = try await DuplicateScanner(store: store).scan()

        #expect(report.groups.isEmpty)
        #expect(report.unreachableGalleries == [second.url.lastPathComponent])
    }
}

struct DuplicateTrasherTests {
    @Test func movesTheCopyToTheTrashAndPutsItBack() async throws {
        let name = uniqueRawName()
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile(name, contents: "same picture")
        try second.writeFile(name, contents: "same picture")
        try second.writeFile("DSC2.ARW", contents: "not a duplicate")
        let keptBefore = try first.snapshot()

        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        _ = try await indexGallery(first, store: store)
        let secondId = try await indexGallery(second, store: store)
        let group = try #require(try await DuplicateScanner(store: store).scan().groups.first)
        let keep = try #require(group.copies.first { $0.photoId == group.proposal.photoId })
        let extra = try #require(group.copies.first { $0.photoId != keep.photoId })
        try await store.saveCulling([CullingResult(photoId: extra.photoId, verdict: .keep, reasons: [])], analyzedAt: Date())
        let galleries = try await store.galleryLocations()
        let trasher = DuplicateTrasher(store: store)
        let extraURL = second.url.appending(path: name)

        let outcome = try await trasher.moveToTrash(
            [TrashSelection(sha256: group.sha256, keep: keep, trash: [extra])],
            galleries: galleries,
            writableFolders: [secondId: second.url]
        )

        // The copy is in the trash, not deleted; the kept copy did not change at all.
        let trashed = try #require(outcome.trashed.first)
        #expect(outcome.trashed.count == 1 && outcome.skipped.isEmpty)
        #expect(outcome.trashedBytes == Int64("same picture".utf8.count))
        #expect(!FileManager.default.fileExists(atPath: extraURL.path))
        #expect(FileManager.default.fileExists(atPath: trashed.trashURL.path))
        #expect(trashed.trashURL.pathComponents.contains(".Trash"), "got \(trashed.trashURL.path)")
        #expect(try VerifiedCopier.sha256(of: trashed.trashURL) == group.sha256)
        #expect(try first.snapshot() == keptBefore)
        // The catalogue follows: the photo is gone, the gallery counts one file less.
        var context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Photo>()).map(\.id).contains(extra.photoId) == false)
        #expect(try context.fetch(FetchDescriptor<Gallery>()).first { $0.id == secondId }?.photoCount == 1)

        let restored = try await trasher.restore(
            outcome.trashed, galleryNames: [:], writableFolders: [secondId: second.url]
        )

        #expect(restored == RestoreOutcome(restored: 1, skipped: []))
        #expect(try VerifiedCopier.sha256(of: extraURL) == group.sha256)
        #expect(!FileManager.default.fileExists(atPath: trashed.trashURL.path))
        context = ModelContext(container)
        let photo = try #require(try context.fetch(FetchDescriptor<Photo>()).first { $0.id == extra.photoId })
        #expect(photo.relativePath == name && photo.gallery?.id == secondId)
        #expect(photo.sha256 == group.sha256 && photo.cullingVerdict == .keep, "restored as it was")
        #expect(try context.fetch(FetchDescriptor<Gallery>()).first { $0.id == secondId }?.photoCount == 2)
    }

    @Test func nothingMovesWhenTheKeptCopyChanged() async throws {
        let name = uniqueRawName()
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile(name, contents: "same picture")
        try second.writeFile(name, contents: "same picture")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        _ = try await indexGallery(first, store: store)
        let secondId = try await indexGallery(second, store: store)
        let group = try #require(try await DuplicateScanner(store: store).scan().groups.first)
        let keep = try #require(group.copies.first { $0.galleryId != secondId })
        let extra = try #require(group.copies.first { $0.galleryId == secondId })
        try first.writeFile(name, contents: "edited picture") // edited after the search
        let before = try second.snapshot()

        let outcome = try await DuplicateTrasher(store: store).moveToTrash(
            [TrashSelection(sha256: group.sha256, keep: keep, trash: [extra])],
            galleries: try await store.galleryLocations(),
            writableFolders: [secondId: second.url]
        )

        #expect(outcome.trashed.isEmpty)
        #expect(outcome.skipped.map(\.reason) == [.keptCopyChanged])
        #expect(try second.snapshot() == before)
    }

    @Test func skipsACopyThatChangedOrCannotBeWritten() async throws {
        let name = uniqueRawName()
        let (first, second, third) = try (TestFolder(), TestFolder(), TestFolder())
        defer { first.remove(); second.remove(); third.remove() }
        for folder in [first, second, third] {
            try folder.writeFile(name, contents: "same picture")
        }
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        let firstId = try await indexGallery(first, store: store)
        let secondId = try await indexGallery(second, store: store)
        let thirdId = try await indexGallery(third, store: store)
        let group = try #require(try await DuplicateScanner(store: store).scan().groups.first)
        let byGallery = Dictionary(uniqueKeysWithValues: group.copies.map { ($0.galleryId, $0) })
        try second.writeFile(name, contents: "SAME PICTURE") // same size, other content
        let before = (try second.snapshot(), try third.snapshot())

        let outcome = try await DuplicateTrasher(store: store).moveToTrash(
            [TrashSelection(sha256: group.sha256, keep: byGallery[firstId]!, trash: [byGallery[secondId]!, byGallery[thirdId]!])],
            galleries: try await store.galleryLocations(),
            writableFolders: [secondId: second.url] // the third folder was not allowed
        )

        #expect(outcome.trashed.isEmpty)
        #expect(outcome.skipped.map(\.reason) == [.notIdentical, .noWriteAccess])
        #expect(try second.snapshot() == before.0)
        #expect(try third.snapshot() == before.1)
    }

    @Test func undoNeverReplacesAFile() async throws {
        let name = uniqueRawName()
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile(name, contents: "same picture")
        try second.writeFile(name, contents: "same picture")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        _ = try await indexGallery(first, store: store)
        let secondId = try await indexGallery(second, store: store)
        let group = try #require(try await DuplicateScanner(store: store).scan().groups.first)
        let trasher = DuplicateTrasher(store: store)
        let outcome = try await trasher.moveToTrash(
            [TrashSelection(sha256: group.sha256, keep: group.copies[0], trash: [group.copies[1]])],
            galleries: try await store.galleryLocations(),
            writableFolders: [secondId: second.url]
        )
        let trashed = try #require(outcome.trashed.first)
        defer { try? FileManager.default.removeItem(at: trashed.trashURL) } // test file only
        try second.writeFile(name, contents: "a new photo with the same name")

        let restored = try await trasher.restore(outcome.trashed, galleryNames: [secondId: "B"], writableFolders: [secondId: second.url])

        #expect(restored.restored == 0)
        #expect(restored.skipped == [SkippedFile(galleryName: "B", relativePath: name, reason: .nameTaken)])
        #expect(try String(contentsOf: second.url.appending(path: name), encoding: .utf8) == "a new photo with the same name")
        #expect(FileManager.default.fileExists(atPath: trashed.trashURL.path))
    }

    @Test func undoLeavesAnotherFileFoundAtTheSamePlaceInTheTrash() async throws {
        let name = uniqueRawName()
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile(name, contents: "same picture")
        try second.writeFile(name, contents: "same picture")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        _ = try await indexGallery(first, store: store)
        let secondId = try await indexGallery(second, store: store)
        let group = try #require(try await DuplicateScanner(store: store).scan().groups.first)
        let trasher = DuplicateTrasher(store: store)
        let outcome = try await trasher.moveToTrash(
            [TrashSelection(sha256: group.sha256, keep: group.copies[0], trash: [group.copies[1]])],
            galleries: try await store.galleryLocations(),
            writableFolders: [secondId: second.url]
        )
        let trashed = try #require(outcome.trashed.first)
        defer { try? FileManager.default.removeItem(at: trashed.trashURL) } // test file only
        // The trash was emptied, then another file with that name was put in it.
        let handle = try FileHandle(forWritingTo: trashed.trashURL)
        try handle.write(contentsOf: Data("SAME PICTURE".utf8))
        try handle.close()

        let restored = try await trasher.restore(outcome.trashed, galleryNames: [secondId: "B"], writableFolders: [secondId: second.url])

        #expect(restored.restored == 0)
        #expect(restored.skipped.map(\.reason) == [.notInTrash])
        #expect(!FileManager.default.fileExists(atPath: second.url.appending(path: name).path))
        #expect(try String(contentsOf: trashed.trashURL, encoding: .utf8) == "SAME PICTURE")
    }
}

@MainActor
struct DuplicatesControllerTests {
    @Test func asksForAccessOnceThenTrashesTheChosenCopyAndUndoes() async throws {
        let name = uniqueRawName()
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile(name, contents: "same picture")
        try second.writeFile(name, contents: "same picture")
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let firstId = try await indexGallery(first, store: store)
        _ = try await indexGallery(second, store: store)
        var askedFor: [String] = []
        let controller = DuplicatesController(store: store) { gallery in
            askedFor.append(gallery.name)
            return first.url
        }

        controller.scan()
        await controller.waitUntilIdle()
        let group = try #require(controller.report?.groups.first)
        #expect(controller.keepsProposal(in: group))
        // The user keeps the copy of the newer gallery instead: the one of the older gallery goes.
        let newerCopy = try #require(group.copies.first { $0.galleryId != firstId })
        controller.keep(newerCopy.photoId, in: group)
        #expect(!controller.keepsProposal(in: group))
        #expect(controller.selectedCopyCount == 1)
        let firstFile = first.url.appending(path: name)

        controller.moveSelectionToTrash()
        await controller.waitUntilIdle()

        #expect(askedFor == [first.url.lastPathComponent])
        #expect(controller.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: firstFile.path))
        #expect(FileManager.default.fileExists(atPath: second.url.appending(path: name).path))
        #expect(controller.lastTrash?.files.count == 1)
        #expect(controller.report?.groups.isEmpty == true)
        let gallery = try #require(try ModelContext(container).fetch(FetchDescriptor<Gallery>()).first { $0.id == firstId })
        #expect(gallery.writeBookmark != nil, "the permission is saved: not asked again")

        controller.undoLastTrash()
        await controller.waitUntilIdle()

        #expect(askedFor.count == 1)
        #expect(controller.errorMessage == nil)
        #expect(controller.lastTrash == nil)
        #expect(try String(contentsOf: firstFile, encoding: .utf8) == "same picture")
        #expect(controller.report?.groups.count == 1)
    }

    @Test func aRefusedFolderLeavesEverythingInPlace() async throws {
        let name = uniqueRawName()
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile(name, contents: "same picture")
        try second.writeFile(name, contents: "same picture")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        _ = try await indexGallery(first, store: store)
        _ = try await indexGallery(second, store: store)
        let before = try second.snapshot()
        let controller = DuplicatesController(store: store) { _ in nil }
        controller.scan()
        await controller.waitUntilIdle()

        controller.moveSelectionToTrash()
        await controller.waitUntilIdle()

        #expect(try second.snapshot() == before)
        #expect(controller.lastTrash == nil)
        #expect(controller.report?.groups.count == 1)
    }
}

struct CardImportFingerprintTests {
    @Test func aCardImportStoresItsFingerprintsAndWriteAccess() async throws {
        let (card, destination) = try (TestFolder(), TestFolder())
        defer { card.remove(); destination.remove() }
        try card.writeJPEG("DCIM/100MSDCF/DSC00001.JPG", exifDate: "2026:10:14 10:00:00")
        try card.writeFile("DCIM/100MSDCF/DSC00002.ARW", contents: "raw")
        let contents = try CardScanner.scan(card: card.url)
        let container = try makeInMemoryContainer()

        let report = try await CardImporter(store: LibraryStore(modelContainer: container)).importCard(CardImportRequest(
            card: contents, destination: destination.url, sessionName: "Test", sessionDate: try #require(contents.earliestDate)
        ))

        let context = ModelContext(container)
        let photos = try context.fetch(FetchDescriptor<Photo>())
        #expect(photos.count == 2)
        for photo in photos {
            let copied = try #require(report.copiedFiles.first { $0.destination.lastPathComponent == photo.relativePath })
            #expect(photo.sha256 == copied.sha256)
        }
        #expect(try context.fetch(FetchDescriptor<Gallery>()).first?.writeBookmark != nil)
    }
}

// MARK: - Helpers

/// The trash is the user's, shared by every test running at the same time: a file name used once
/// only, so a test never finds another test's file at "its" place in the trash.
private func uniqueRawName() -> String {
    "DSC-\(UUID().uuidString.prefix(8)).ARW"
}

/// Indexes a test folder as a gallery (F2) and returns its id.
private func indexGallery(_ folder: TestFolder, store: LibraryStore) async throws -> UUID {
    switch try await FolderIndexer(store: store).indexFolder(at: folder.url) {
    case .indexed(let galleryId, _), .alreadyIndexed(let galleryId):
        return galleryId
    }
}

@MainActor
private final class ScanProgressRecorder {
    var values: [DuplicateScanProgress] = []
}
