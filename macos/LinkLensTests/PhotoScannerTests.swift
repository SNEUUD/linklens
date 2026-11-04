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

    @Test func listsVideosButNotTheCopiesASonyWritesNextToThem() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        // A Sony card copied by hand in the Finder.
        for name in [
            "DCIM/100MSDCF/DSC00001.ARW", "DCIM/100APPLE/IMG_0002.MOV",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4", "PRIVATE/M4ROOT/CLIP/C0001M01.XML",
            "PRIVATE/M4ROOT/THMBNL/C0001T01.JPG", "PRIVATE/M4ROOT/SUB/C0001S03.MP4",
            "PRIVATE/AVCHD/BDMV/STREAM/00000.MTS", "Montage/film.m4v",
        ] {
            try folder.writeFile(name)
        }

        let files = try PhotoScanner.scan(folder: folder.url)

        #expect(files.map(\.relativePath) == [
            "DCIM/100APPLE/IMG_0002.MOV", "DCIM/100MSDCF/DSC00001.ARW", "Montage/film.m4v",
            "PRIVATE/AVCHD/BDMV/STREAM/00000.MTS", "PRIVATE/M4ROOT/CLIP/C0001.MP4",
        ])
        #expect(files.map(\.kind) == [.video, .photo, .video, .video, .video])
    }

    @Test func aFolderNamedThumbnailsElsewhereIsRead() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeFile("THMBNL/DSC1.JPG") // not under M4ROOT: a folder of the user's
        try folder.writeFile("SUB/clip.mp4")

        #expect(try PhotoScanner.scan(folder: folder.url).map(\.relativePath) == ["SUB/clip.mp4", "THMBNL/DSC1.JPG"])
    }

    @Test func ignoresFoldersNamedLikePhotos() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url.appending(path: "trap.jpg"), withIntermediateDirectories: true)

        #expect(try PhotoScanner.scan(folder: folder.url).isEmpty)
    }
}
