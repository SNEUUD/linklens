import Foundation

/// A photo file found in the source folder.
public struct PhotoFile: Sendable, Hashable {
    public let url: URL
    /// Path relative to the source folder, used as the photo identifier in reports.
    public let relativePath: String
    public let fileSize: Int64
}

/// Lists the supported photos of a folder. Never writes anything.
public enum PhotoScanner {
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "arw"]

    public static func scan(folder: URL) throws -> [PhotoFile] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ProbeError.folderNotFound(root.path)
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

    /// True if `child` is `parent` itself or somewhere inside it.
    public static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}
