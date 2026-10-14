import Foundation
import Testing
@testable import LinkLens

struct PhotoScannerTests {
    @Test func keepsOnlySupportedPhotosInNaturalOrder() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        for name in ["DSC10.ARW", "DSC2.arw", "IMG_1.HEIC", "photo.JPG", "photo2.jpeg", "notes.txt", "DSC3.ARW.xmp", ".hidden.jpg", "Jour 2/DSC1.ARW"] {
            try folder.writeFile(name)
        }

        let files = try PhotoScanner.scan(folder: folder.url)

        #expect(files.map(\.relativePath) == ["DSC2.arw", "DSC10.ARW", "IMG_1.HEIC", "Jour 2/DSC1.ARW", "photo.JPG", "photo2.jpeg"])
        #expect(files.allSatisfy { $0.fileSize == Int64("not a photo".utf8.count) })
    }

    @Test func ignoresFoldersNamedLikePhotos() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url.appending(path: "trap.jpg"), withIntermediateDirectories: true)

        #expect(try PhotoScanner.scan(folder: folder.url).isEmpty)
    }
}
