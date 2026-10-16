import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// Batch 5: the card import window (counts, preview photos, folder preview) and the folder drop.
struct ImportWindowTests {
    private let french = Locale(identifier: "fr_FR")
    private let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        // `try!` is fine in a test helper: a malformed literal is a bug of the test itself.
        try! Date(text, strategy: .iso8601)
    }

    private func card(photos: Int, videos: Int = 0, dates: [Date?] = []) -> CardContents {
        let photoFiles = (0..<photos).map { index in
            CardFile(
                url: URL(filePath: "/Volumes/SDTEST/DCIM/100MSDCF/DSC\(String(format: "%05d", index + 1)).ARW"),
                relativePath: "DCIM/100MSDCF/DSC\(String(format: "%05d", index + 1)).ARW",
                fileSize: 24_000_000, kind: .photo,
                captureDate: index < dates.count ? dates[index] : nil, modificationDate: nil
            )
        }
        let videoFiles = (0..<videos).map { index in
            CardFile(
                url: URL(filePath: "/Volumes/SDTEST/PRIVATE/M4ROOT/CLIP/C000\(index + 1).MP4"),
                relativePath: "PRIVATE/M4ROOT/CLIP/C000\(index + 1).MP4",
                fileSize: 80_000_000, kind: .video, captureDate: nil, modificationDate: nil
            )
        }
        return CardContents(root: URL(filePath: "/Volumes/SDTEST"), name: "SDTEST", files: photoFiles + videoFiles, notImported: [])
    }

    // MARK: - Folder preview

    @Test func pathPreviewFollowsTheNameAndTheDate() {
        let day = date("2026-09-20T12:40:57Z")
        #expect(ImportPathPreview.text(date: day, sessionName: "Mariage Julie & Tom", calendar: paris) == "2026 / 2026-09-20 Mariage Julie & Tom /")
        #expect(ImportPathPreview.text(date: day, sessionName: "", calendar: paris) == "2026 / 2026-09-20 /")
        // Same cleaning as the folder really created: no « / », single spaces.
        #expect(ImportPathPreview.text(date: day, sessionName: "  Julie/Tom   soirée ", calendar: paris) == "2026 / 2026-09-20 Julie-Tom soirée /")
        // The camera's local day: 23:30 in Paris is still the 31st of December there.
        #expect(ImportPathPreview.text(date: date("2026-12-31T22:30:00Z"), sessionName: "Réveillon", calendar: paris) == "2026 / 2026-12-31 Réveillon /")
        #expect(ImportPathPreview.spokenText(date: day, sessionName: "Mariage", calendar: paris).contains("2026-09-20 Mariage"))
    }

    /// The preview in the window follows what is typed, character after character.
    @MainActor
    @Test func controllerPreviewUpdatesWhileTyping() throws {
        let container = try makeInMemoryContainer()
        let controller = CardImportController(importer: CardImporter(store: LibraryStore(modelContainer: container)))
        controller.sessionDate = date("2026-09-20T12:40:57Z")
        controller.sessionName = "Mar"
        #expect(controller.plannedFolder.hasSuffix("2026-09-20 Mar /"))
        controller.sessionName = "Mariage"
        #expect(controller.plannedFolder.hasSuffix("2026-09-20 Mariage /"))
    }

    @Test func locationIsShortenedInsideTheHomeFolder() {
        let home = ["Macintosh HD", "Utilisateurs", "chris"]
        #expect(ImportDestination.shortened(home + ["Images", "LinkLens"], home: home) == ["Images", "LinkLens"])
        // On another disk, the whole path stays: the disk's name matters.
        #expect(ImportDestination.shortened(["Photos 2TB", "LinkLens"], home: home) == ["Photos 2TB", "LinkLens"])
        // The home folder itself is not shortened to nothing.
        #expect(ImportDestination.shortened(home, home: home) == home)
    }

    // MARK: - Preview photos and counts

    @Test func previewPhotosAreSpreadOverTheWholeCard() {
        #expect(CardImportSummary.evenlySpread(Array(0..<11), count: 7) == [0, 2, 3, 5, 7, 8, 10])
        #expect(CardImportSummary.evenlySpread(Array(0..<3), count: 7) == [0, 1, 2])
        #expect(CardImportSummary.evenlySpread(Array(0..<5), count: 1) == [0])
        #expect(CardImportSummary.evenlySpread([Int](), count: 7).isEmpty)

        let summary = CardImportSummary(card: card(photos: 20, videos: 1))
        let names = summary.previewFiles.map { ($0.relativePath as NSString).lastPathComponent }
        #expect(names.count == 7)
        #expect(names.first == "DSC00001.ARW")
        #expect(names.last == "DSC00020.ARW")
        // Videos have no preview: never in the strip, counted in « +N ».
        #expect(summary.previewFiles.allSatisfy { $0.kind == .photo })
        #expect(summary.hiddenCount == 14)
    }

    @Test func countsOfTheCard() {
        // The mockup's card: 10 photos and 1 video → 7 photos shown, « +4 », « Importer 11 fichiers ».
        let mockup = CardImportSummary(card: card(photos: 10, videos: 1))
        #expect(mockup.photoCount == 10)
        #expect(mockup.videoCount == 1)
        #expect(mockup.fileCount == 11)
        #expect(mockup.previewFiles.count == 7)
        #expect(mockup.hiddenCount == 4)

        let small = CardImportSummary(card: card(photos: 3, videos: 2))
        #expect(small.previewFiles.count == 3)
        #expect(small.hiddenCount == 2)

        let videosOnly = CardImportSummary(card: card(photos: 0, videos: 2))
        #expect(videosOnly.previewFiles.isEmpty)
        #expect(videosOnly.hiddenCount == 2)
        #expect(!videosOnly.line(locale: french, calendar: paris).contains("photo"))
    }

    @Test func headerLineWithCountsAndDates() {
        let day = date("2026-09-20T12:40:57Z")
        let oneDay = CardImportSummary(card: card(photos: 10, videos: 1, dates: [day, day.addingTimeInterval(3_600)]))
        let line = oneDay.line(locale: french, calendar: paris)
        #expect(line.hasPrefix("10 photos · 1 vidéo · "))
        #expect(line.hasSuffix("prises le 20 sept. 2026"))

        let twoDays = CardImportSummary(card: card(photos: 2, dates: [date("2026-09-19T18:00:00Z"), day]))
        #expect(twoDays.datesTaken(locale: french, calendar: paris) == "prises du 19 au 20 sept. 2026")

        let twoMonths = CardImportSummary(card: card(photos: 2, dates: [date("2026-09-30T18:00:00Z"), date("2026-10-02T09:00:00Z")]))
        #expect(twoMonths.datesTaken(locale: french, calendar: paris) == "prises du 30 sept. au 2 oct. 2026")

        let twoYears = CardImportSummary(card: card(photos: 2, dates: [date("2025-12-30T18:00:00Z"), date("2026-01-02T09:00:00Z")]))
        #expect(twoYears.datesTaken(locale: french, calendar: paris) == "prises du 30 déc. 2025 au 2 janv. 2026")

        let noDate = CardImportSummary(card: card(photos: 2))
        #expect(noDate.datesTaken(locale: french, calendar: paris) == nil)
        #expect(noDate.line(locale: french, calendar: paris) == "2 photos")
    }

    // MARK: - Folder drop

    @Test func dropAcceptsOneFolderOnly() {
        let folder = URL(filePath: "/Users/chris/Photos/Mariage", directoryHint: .isDirectory)
        let file = URL(filePath: "/Users/chris/Photos/DSC00001.ARW")
        let folderItem = FolderDrop.Item(name: "Mariage", isDirectory: true)
        let fileItem = FolderDrop.Item(name: "DSC00001.ARW", isDirectory: false)

        #expect(FolderDrop.decide([(folder, folderItem)]) == .indexFolder(folder))
        #expect(FolderDrop.decide([(file, fileItem)]) == .rejected(.notAFolder(name: "DSC00001.ARW")))
        #expect(FolderDrop.decide([(folder, folderItem), (folder, folderItem)]) == .rejected(.severalItems))
        #expect(FolderDrop.decide([(folder, folderItem), (file, fileItem)]) == .rejected(.severalItems))
        // A picture dragged from a web page: no file URL at all.
        #expect(FolderDrop.decide([]) == .rejected(.notFromFinder))
        // A Photos library looks like a file in the Finder.
        let library = FolderDrop.Item(name: "Photos Library.photoslibrary", isDirectory: true, isPackage: true)
        #expect(FolderDrop.decide([(folder, library)]) == .rejected(.notAFolder(name: "Photos Library.photoslibrary")))
    }

    @Test func dropOfACameraCardOpensTheCardImport() {
        let card = URL(filePath: "/Volumes/SDTEST", directoryHint: .isDirectory)
        let cardItem = FolderDrop.Item(name: "SDTEST", isDirectory: true, isVolumeRoot: true, hasCameraFolder: true)
        #expect(FolderDrop.decide([(card, cardItem)]) == .importCard(card))

        // An external disk without DCIM: an ordinary folder, indexed in place.
        let disk = URL(filePath: "/Volumes/Photos 2TB", directoryHint: .isDirectory)
        let diskItem = FolderDrop.Item(name: "Photos 2TB", isDirectory: true, isVolumeRoot: true)
        #expect(FolderDrop.decide([(disk, diskItem)]) == .indexFolder(disk))

        // A folder of the card: refused, so the photos are not left on a card about to be formatted.
        let dcim = URL(filePath: "/Volumes/SDTEST/DCIM/100MSDCF", directoryHint: .isDirectory)
        let dcimItem = FolderDrop.Item(name: "100MSDCF", isDirectory: true, isInsideCameraCard: true)
        #expect(FolderDrop.decide([(dcim, dcimItem)]) == .rejected(.insideCameraCard(name: "100MSDCF")))
    }

    @Test func dropReadsFolderOrFileFromTheDisk() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let photo = try folder.writeJPEG("Séance/DSC00001.JPG")
        let package = folder.url.appending(path: "Outil.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let session = folder.url.appending(path: "Séance", directoryHint: .isDirectory)

        let sessionItem = FolderDrop.item(at: session)
        #expect(sessionItem.isDirectory)
        #expect(!sessionItem.isPackage)
        #expect(!sessionItem.isVolumeRoot)
        #expect(FolderDrop.decide([(session, sessionItem)]) == .indexFolder(session))

        let photoItem = FolderDrop.item(at: photo)
        #expect(FolderDrop.decide([(photo, photoItem)]) == .rejected(.notAFolder(name: "DSC00001.JPG")))

        let packageItem = FolderDrop.item(at: package)
        #expect(packageItem.isPackage)
        #expect(FolderDrop.decide([(package, packageItem)]) == .rejected(.notAFolder(name: packageItem.name)))
        // Nothing was written or moved by looking.
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path) == ["DSC00001.JPG"])
    }

    @Test func rejectionsSayWhatToDo() {
        #expect(FolderDrop.Rejection.notAFolder(name: "DSC00001.ARW").message.contains("Ajouter un dossier"))
        #expect(FolderDrop.Rejection.insideCameraCard(name: "100MSDCF").message.contains("Importer une carte SD"))
        #expect(!FolderDrop.Rejection.severalItems.title.isEmpty)
    }
}
