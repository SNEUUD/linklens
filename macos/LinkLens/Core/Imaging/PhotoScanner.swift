import Foundation

/// A photo file found in the gallery folder.
struct PhotoFile: Sendable, Hashable {
    let url: URL
    /// Path relative to the gallery folder, stored in `Photo.relativePath`.
    let relativePath: String
    let fileSize: Int64
}

/// Lists the supported photos of a folder and its subfolders. Never writes anything.
enum PhotoScanner {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "arw"]

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
}
