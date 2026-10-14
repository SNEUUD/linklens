import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// F1: importing a camera card (scan, layout, verified copy, cancellation, gallery).
struct CardImportTests {
    // MARK: - Scanning the card

    @Test func scanFindsPhotosAndVideosAndListsUnsupportedFiles() throws {
        let card = try TestFolder()
        defer { card.remove() }
        try card.writeJPEG("DCIM/100MSDCF/DSC00001.JPG", exifDate: "2026:10:14 09:00:00")
        try card.writeFile("DCIM/100MSDCF/DSC00002.ARW")
        try card.writeFile("DCIM/100MSDCF/._DSC00002.ARW") // written by macOS on FAT cards
        try card.writeFile("DCIM/101MSDCF/DSC00010.JPG")
        try card.writeFile("DCIM/100APPLE/IMG_0002.MOV")
        try card.writeFile("DCIM/100CANON/IMG_0001.CR3")
        try card.writeFile("DCIM/100CANON/MVI_0001.THM")
        try card.writeFile("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        try card.writeFile("PRIVATE/M4ROOT/CLIP/C0001M01.XML")
        try card.writeFile("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG")
        try card.writeFile("notes.txt")

        let contents = try CardScanner.scan(card: card.url)

        #expect(contents.files.map(\.relativePath) == [
            "DCIM/100APPLE/IMG_0002.MOV",
            "DCIM/100MSDCF/DSC00001.JPG",
            "DCIM/100MSDCF/DSC00002.ARW",
            "DCIM/101MSDCF/DSC00010.JPG",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
        ])
        #expect(contents.files.map(\.kind) == [.video, .photo, .photo, .photo, .video])
        #expect(contents.photoCount == 3 && contents.videoCount == 2)
        #expect(contents.notImported == ["DCIM/100CANON/IMG_0001.CR3"])
        let dsc1 = try #require(contents.files.first { $0.relativePath.hasSuffix("DSC00001.JPG") })
        #expect(dsc1.captureDate == PhotoMetadataReader.parseExifDate("2026:10:14 09:00:00", subseconds: nil))
    }

    @Test func folderWithoutDCIMIsNotACard() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("DSC00001.JPG")

        #expect(throws: CardImportError.notACameraCard(folder.url.lastPathComponent)) {
            try CardScanner.scan(card: folder.url)
        }
    }

    @Test func sessionDateIsTheEarliestExifDateElseTheFileDate() throws {
        let card = try TestFolder()
        defer { card.remove() }
        try card.writeJPEG("DCIM/100MSDCF/DSC00001.JPG", exifDate: "2026:10:14 15:00:00")
        try card.writeJPEG("DCIM/100MSDCF/DSC00002.JPG", exifDate: "2026:10:13 23:30:00")
        let noExif = try card.writeJPEG("DCIM/100MSDCF/DSC00003.JPG")
        let fileDate = try #require(PhotoMetadataReader.parseExifDate("2026:10:12 08:00:00", subseconds: nil))

        #expect(try CardScanner.scan(card: card.url).earliestDate == PhotoMetadataReader.parseExifDate("2026:10:13 23:30:00", subseconds: nil))

        try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: noExif.path)
        let contents = try CardScanner.scan(card: card.url)
        #expect(contents.earliestDate == fileDate)
        #expect(contents.files.first { $0.relativePath.hasSuffix("DSC00003.JPG") }?.captureDate == nil)
    }

    // MARK: - Layout

    @Test func foldersAreNamedByYearThenDayAndSession() throws {
        let date = try #require(PhotoMetadataReader.parseExifDate("2026:10:14 09:00:00", subseconds: nil))
        let names = ImportLayout.folderNames(date: date, sessionName: "Mariage Julie & Tom")
        #expect(names.year == "2026")
        #expect(names.session == "2026-10-14 Mariage Julie & Tom")
        #expect(ImportLayout.folderNames(date: date, sessionName: "   ").session == "2026-10-14")
        #expect(ImportLayout.numberedFolderName("2026-10-14 Mariage", number: 1) == "2026-10-14 Mariage")
        #expect(ImportLayout.numberedFolderName("2026-10-14 Mariage", number: 2) == "2026-10-14 Mariage (2)")
    }

    @Test func sessionNamesAreSafeFolderNames() {
        #expect(ImportLayout.sanitizedSessionName("Mariage / Julie: Tom") == "Mariage - Julie- Tom")
        #expect(ImportLayout.sanitizedSessionName("  Baptême\n  Léa  ") == "Baptême Léa")
        #expect(ImportLayout.sanitizedSessionName("..cachée") == "cachée")
        #expect(ImportLayout.sanitizedSessionName(String(repeating: "a", count: 200)).count == ImportLayout.maxSessionNameLength)
    }

    @Test func filesWithTheSameNameGetANumber() {
        let names = ImportLayout.destinationNames(for: [
            "DCIM/100MSDCF/DSC00001.JPG",
            "DCIM/101MSDCF/DSC00001.JPG",
            "DCIM/100MSDCF/DSC00001.ARW",
            "DCIM/102MSDCF/dsc00001.jpg",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
        ])
        #expect(names == ["DSC00001.JPG", "DSC00001 (2).JPG", "DSC00001.ARW", "dsc00001 (3).jpg", "C0001.MP4"])
    }

    // MARK: - Copy and verification

    @Test func importCopiesChecksAndIndexesWithoutTouchingTheCard() async throws {
        let card = try makeCard()
        let destination = try TestFolder()
        defer { card.remove(); destination.remove() }
        let before = try card.snapshot()
        let container = try makeInMemoryContainer()
        let importer = CardImporter(store: LibraryStore(modelContainer: container), indexingBatchSize: 2)
        let recorder = CardProgressRecorder()

        let report = try await importer.importCard(try request(card: card, destination: destination)) { progress in
            recorder.values.append(progress)
        }

        #expect(try card.snapshot() == before)
        #expect(report.canFormatCard)
        #expect(report.failures.isEmpty)
        #expect(report.sessionPath == "2026/2026-10-14 Mariage Julie & Tom")
        let sessionFolder = destination.url.appending(path: "2026/2026-10-14 Mariage Julie & Tom")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessionFolder.path).sorted()
            == ["C0001.MP4", "DSC00001 (2).JPG", "DSC00001.JPG", "DSC00002.JPG"])

        // Each copy has the original's fingerprint, checked again here from the files themselves.
        for copied in report.copiedFiles {
            let original = card.url.appending(path: copied.sourcePath)
            #expect(try VerifiedCopier.sha256(of: original) == copied.sha256)
            #expect(try VerifiedCopier.sha256(of: copied.destination) == copied.sha256)
            #expect(try Data(contentsOf: original) == Data(contentsOf: copied.destination))
        }
        #expect(Set(report.copiedFiles.map(\.sourcePath)) == [
            "DCIM/100MSDCF/DSC00001.JPG", "DCIM/100MSDCF/DSC00002.JPG",
            "DCIM/101MSDCF/DSC00001.JPG", "PRIVATE/M4ROOT/CLIP/C0001.MP4",
        ])

        // The gallery is indexed like F2, with the video listed but kept out of the AI sorting.
        let context = ModelContext(container)
        let gallery = try #require(try context.fetch(FetchDescriptor<Gallery>()).first)
        #expect(report.galleryId == gallery.id)
        #expect(gallery.name == "2026-10-14 Mariage Julie & Tom")
        #expect(gallery.photoCount == 4 && gallery.videoCount == 1)
        #expect(gallery.indexedAt != nil)
        let photos = try context.fetch(FetchDescriptor<Photo>())
        #expect(photos.filter { $0.mediaKind == .video }.map(\.relativePath) == ["C0001.MP4"])
        let culled = try await LibraryStore(modelContainer: container).cullingContents(galleryId: gallery.id)
        #expect(culled.photos.count == 3)

        let progress = await recorder.values
        let lastCopy = try #require(progress.last { $0.phase == .copying })
        #expect(lastCopy.completedBytes == lastCopy.totalBytes && lastCopy.completedFiles == 4)
        #expect(progress.last?.phase == .indexing && progress.last?.completedFiles == 4)
    }

    @Test func corruptedCopyBlocksFormattingAndIsNotKept() async throws {
        let card = try makeCard()
        let destination = try TestFolder()
        defer { card.remove(); destination.remove() }
        let before = try card.snapshot()
        let container = try makeInMemoryContainer()
        // A faulty disk: one byte of DSC00002 changes between writing and checking.
        let importer = CardImporter(store: LibraryStore(modelContainer: container)) { temporary in
            guard temporary.lastPathComponent.contains("DSC00002") else { return }
            let handle = try FileHandle(forUpdating: temporary)
            defer { try? handle.close() }
            try handle.seek(toOffset: 20)
            let byte = try #require(try handle.read(upToCount: 1)?.first)
            try handle.seek(toOffset: 20)
            try handle.write(contentsOf: Data([byte ^ 0xFF]))
        }

        let report = try await importer.importCard(try request(card: card, destination: destination))

        #expect(!report.canFormatCard)
        #expect(report.failures == [CardImportFailure(relativePath: "DCIM/100MSDCF/DSC00002.JPG", reason: .mismatch)])
        #expect(report.copiedFiles.count == 3)
        // The bad copy is gone (no hidden temporary file either); the good ones are kept and indexed.
        let sessionFolder = destination.url.appending(path: "2026/2026-10-14 Mariage Julie & Tom")
        let names = try FileManager.default.contentsOfDirectory(atPath: sessionFolder.path).sorted()
        #expect(names == ["C0001.MP4", "DSC00001 (2).JPG", "DSC00001.JPG"])
        #expect(try card.snapshot() == before)
        let gallery = try #require(try ModelContext(container).fetch(FetchDescriptor<Gallery>()).first)
        #expect(gallery.photoCount == 3)
    }

    @Test func unsupportedFilesLeftOnTheCardBlockFormatting() async throws {
        let card = try TestFolder()
        let destination = try TestFolder()
        defer { card.remove(); destination.remove() }
        try card.writeJPEG("DCIM/100CANON/IMG_0001.JPG", exifDate: "2026:10:14 09:00:00")
        try card.writeFile("DCIM/100CANON/IMG_0001.CR3")
        let importer = CardImporter(store: LibraryStore(modelContainer: try makeInMemoryContainer()))

        let report = try await importer.importCard(try request(card: card, destination: destination))

        #expect(report.copiedFiles.count == 1 && report.failures.isEmpty)
        #expect(report.notImported == ["DCIM/100CANON/IMG_0001.CR3"])
        #expect(!report.canFormatCard)
    }

    @Test func anExistingSessionFolderIsNeverWrittenInto() async throws {
        let card = try makeCard()
        let destination = try TestFolder()
        defer { card.remove(); destination.remove() }
        try destination.writeFile("2026/2026-10-14 Mariage Julie & Tom/DSC00001.JPG", contents: "an earlier import")
        let earlier = try destination.snapshot()
        let importer = CardImporter(store: LibraryStore(modelContainer: try makeInMemoryContainer()))

        let report = try await importer.importCard(try request(card: card, destination: destination))

        #expect(report.sessionPath == "2026/2026-10-14 Mariage Julie & Tom (2)")
        #expect(report.canFormatCard)
        let after = try destination.snapshot()
        for (path, fingerprint) in earlier {
            #expect(after[path] == fingerprint, "\(path) changed")
        }
    }

    @MainActor
    @Test func cancellingRemovesThePartialCopiesFromTheDestinationOnly() async throws {
        let card = try makeCard()
        let destination = try TestFolder()
        defer { card.remove(); destination.remove() }
        try destination.writeFile("autre séance/DSC09999.JPG", contents: "not ours")
        let cardBefore = try card.snapshot()
        let destinationBefore = try destination.snapshot()
        let container = try makeInMemoryContainer()
        let importer = CardImporter(store: LibraryStore(modelContainer: container))
        let importRequest = try request(card: card, destination: destination)

        let box = CardTaskBox()
        box.task = Task {
            try await importer.importCard(importRequest) { progress in
                if progress.completedFiles == 2 { box.task?.cancel() }
            }
        }

        await #expect(throws: CancellationError.self) {
            try await box.task?.value
        }
        #expect(try destination.snapshot() == destinationBefore)
        #expect(try card.snapshot() == cardBefore)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Gallery>()) == 0)
    }

    @Test func copierChecksTheCopyAgainstTheOriginal() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let source = try folder.writeFile("source.bin", contents: String(repeating: "LinkLens ", count: 1_000_000))
        let target = folder.url.appending(path: "copies", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try folder.writeFile("copies/source.bin", contents: "already here")

        let result = try await VerifiedCopier.copy(source, into: target, name: "source.bin")

        // The existing file is kept; the copy takes the next free name.
        #expect(result.url.lastPathComponent == "source (2).bin")
        #expect(try String(contentsOf: target.appending(path: "source.bin"), encoding: .utf8) == "already here")
        #expect(result.sha256 == (try VerifiedCopier.sha256(of: source)))
        #expect(try Data(contentsOf: result.url) == Data(contentsOf: source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == ["source (2).bin", "source.bin"])
    }

    // MARK: - Media kind and card detection

    @Test func mediaKindHasAnUnknownCase() {
        #expect(MediaKind(stored: nil) == .photo) // photos indexed before F1
        #expect(MediaKind(stored: "video") == .video)
        #expect(MediaKind(stored: "hologram") == .unknown)
        #expect(MediaKind(relativePath: "DCIM/100CANON/IMG_0001.CR3") == .unknown)
        #expect(MediaKind(relativePath: "PRIVATE/AVCHD/BDMV/STREAM/00000.MTS") == .video)
    }

    @Test func cameraCardsAreRecognised() {
        let sdCard = VolumeInfo(
            url: URL(filePath: "/Volumes/SDTEST"), name: "SDTEST", isRemovable: true, isEjectable: true,
            isLocal: true, isRootFileSystem: false, fileSystem: "msdos", hasCameraFolder: nil
        )
        #expect(sdCard.looksLikeCameraCard)

        var exFAT = sdCard
        exFAT.fileSystem = "exfat"
        #expect(exFAT.looksLikeCameraCard)

        var installer = sdCard // a downloaded .dmg: ejectable, but APFS or HFS
        installer.isRemovable = false
        installer.fileSystem = "apfs"
        #expect(!installer.looksLikeCameraCard)

        var usbStickWithoutDCIM = sdCard
        usbStickWithoutDCIM.hasCameraFolder = false
        #expect(!usbStickWithoutDCIM.looksLikeCameraCard)

        var ssdWithDCIM = installer
        ssdWithDCIM.hasCameraFolder = true
        #expect(ssdWithDCIM.looksLikeCameraCard)

        var internalDisk = sdCard
        internalDisk.isRemovable = false
        internalDisk.isEjectable = false
        #expect(!internalDisk.looksLikeCameraCard)
    }

    // MARK: - Helpers

    /// A card with two "DSC00001.JPG" (two DCIM folders), a photo and a Sony video with its XML.
    private func makeCard() throws -> TestFolder {
        let card = try TestFolder()
        try card.writeJPEG("DCIM/100MSDCF/DSC00001.JPG", exifDate: "2026:10:14 10:00:00")
        try card.writeJPEG("DCIM/100MSDCF/DSC00002.JPG", width: 120, height: 80, exifDate: "2026:10:14 10:00:01")
        try card.writeJPEG("DCIM/101MSDCF/DSC00001.JPG", exifDate: "2026:10:14 11:00:00")
        try card.writeFile("PRIVATE/M4ROOT/CLIP/C0001.MP4", contents: "not a real video")
        try card.writeFile("PRIVATE/M4ROOT/CLIP/C0001M01.XML", contents: "<xml/>")
        return card
    }

    private func request(card: TestFolder, destination: TestFolder) throws -> CardImportRequest {
        let contents = try CardScanner.scan(card: card.url)
        return CardImportRequest(
            card: contents,
            destination: destination.url,
            sessionName: "Mariage Julie & Tom",
            sessionDate: try #require(contents.earliestDate)
        )
    }
}

@MainActor
private final class CardProgressRecorder {
    var values: [CardImportProgress] = []
}

@MainActor
private final class CardTaskBox {
    var task: Task<CardImportReport, Error>?
}
