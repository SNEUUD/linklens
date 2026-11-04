import Foundation

/// A photo file found in the gallery folder.
struct PhotoFile: Sendable, Hashable {
    let url: URL
    /// Path relative to the gallery folder, stored in `Photo.relativePath`.
    let relativePath: String
    let fileSize: Int64

    var kind: MediaKind { MediaKind(relativePath: relativePath) }
}

/// Lists the supported photos and videos of a folder and its subfolders. Never writes anything.
enum PhotoScanner {
    /// Photos and videos, for a folder added in place (F2) as for a card import (F1).
    static let supportedExtensions = MediaKind.photoExtensions.union(MediaKind.videoExtensions)
    /// What a Sony writes next to each video, in PRIVATE/M4ROOT: a small JPEG (THMBNL/C0001T01.JPG) and,
    /// on recent models, a low-resolution copy (SUB/C0001S03.MP4). On a card copied by hand, they would
    /// show every video a second time. The card import (F1) does not copy them either.
    static let skippedVideoCompanionFolders: Set<String> = ["THMBNL", "SUB"]

    static func scan(folder: URL) throws -> [PhotoFile] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw LibraryError.folderNotFound(root.lastPathComponent)
        }

        var files: [PhotoFile] = []
        for case let url as URL in enumerator {
            if isVideoCompanionFolder(url) {
                enumerator.skipDescendants() // its contents are not even listed
                continue
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let relative = String(resolved.path.dropFirst(root.path.count + 1))
            files.append(PhotoFile(url: resolved, relativePath: relative, fileSize: Int64(values.fileSize ?? 0)))
        }
        // "Natural" order: DSC2 before DSC10, like the Finder.
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Compared without case: the card's file system (exFAT) and the Mac's do not care about it.
    private static func isVideoCompanionFolder(_ url: URL) -> Bool {
        skippedVideoCompanionFolders.contains(url.lastPathComponent.uppercased())
            && url.deletingLastPathComponent().lastPathComponent.uppercased() == "M4ROOT"
    }
}
