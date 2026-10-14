import Foundation

/// A photo or video found on the card, to be copied.
struct CardFile: Sendable, Equatable {
    let url: URL
    /// Path from the card root, e.g. "DCIM/100MSDCF/DSC00001.ARW". Shown in the report.
    let relativePath: String
    let fileSize: Int64
    let kind: MediaKind
    /// EXIF date of a photo; nil for a video or a photo without EXIF.
    let captureDate: Date?
    let modificationDate: Date?

    /// Date used to name the session folder: EXIF first, file date otherwise.
    var sessionDate: Date? { captureDate ?? modificationDate }
}

/// What a card holds, read before anything is copied.
struct CardContents: Sendable, Equatable {
    let root: URL
    let name: String
    /// Photos and videos to copy, in natural order (DSC2 before DSC10).
    let files: [CardFile]
    /// Files in DCIM that LinkLens cannot import (another RAW format, for example). They are not
    /// copied, so they block « Vous pouvez formater la carte ».
    let notImported: [String]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.fileSize } }
    var photoCount: Int { files.filter { $0.kind == .photo }.count }
    var videoCount: Int { files.filter { $0.kind == .video }.count }
    var earliestDate: Date? { files.compactMap(\.sessionDate).min() }
    var latestDate: Date? { files.compactMap(\.sessionDate).max() }
}

/// Lists what a camera card holds. Only reads: names, sizes, dates and the EXIF header of photos.
enum CardScanner {
    /// Every camera writes its photos (and often its videos) under DCIM.
    static let cameraFolder = "DCIM"
    /// Sony keeps its videos outside DCIM: XAVC S in M4ROOT/CLIP, AVCHD in BDMV/STREAM.
    /// Only the videos of these folders are copied (not the XML or thumbnail files next to them).
    static let videoFolders = ["PRIVATE/M4ROOT/CLIP", "PRIVATE/AVCHD/BDMV/STREAM"]
    /// Camera bookkeeping files found in DCIM (video thumbnails, catalogues): safe to lose, never listed.
    static let bookkeepingExtensions: Set<String> = ["thm", "ctg", "xml", "ind", "bnp", "dat", "inf", "bin", "lrv", "db"]

    /// True when `root` has a DCIM folder, i.e. looks like a camera card.
    static func hasCameraFolder(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.appending(path: cameraFolder).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func scan(card root: URL) throws -> CardContents {
        let name = root.lastPathComponent
        guard hasCameraFolder(root) else {
            throw CardImportError.notACameraCard(name)
        }
        var files: [CardFile] = []
        var notImported: [String] = []

        for entry in try listFiles(in: root.appending(path: cameraFolder), cardRoot: root) {
            switch MediaKind(relativePath: entry.relativePath) {
            case .photo:
                let metadata = PhotoMetadataReader.read(url: entry.url)
                files.append(entry.cardFile(kind: .photo, captureDate: metadata.captureDate))
            case .video:
                files.append(entry.cardFile(kind: .video, captureDate: nil))
            case .unknown:
                let fileExtension = (entry.relativePath as NSString).pathExtension.lowercased()
                if !bookkeepingExtensions.contains(fileExtension) {
                    notImported.append(entry.relativePath)
                }
            }
        }
        for folder in videoFolders {
            let url = root.appending(path: folder)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            for entry in try listFiles(in: url, cardRoot: root) where MediaKind(relativePath: entry.relativePath) == .video {
                files.append(entry.cardFile(kind: .video, captureDate: nil))
            }
        }

        let natural: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        return CardContents(
            root: root,
            name: name,
            files: files.sorted { natural($0.relativePath, $1.relativePath) },
            notImported: notImported.sorted(by: natural)
        )
    }

    /// A regular file of the card, before its kind is known.
    private struct Entry {
        let url: URL
        let relativePath: String
        let fileSize: Int64
        let modificationDate: Date?

        func cardFile(kind: MediaKind, captureDate: Date?) -> CardFile {
            CardFile(url: url, relativePath: relativePath, fileSize: fileSize, kind: kind,
                     captureDate: captureDate, modificationDate: modificationDate)
        }
    }

    /// Regular files under `folder`. Hidden files are skipped: macOS writes "._DSC00001.ARW" companions
    /// on FAT cards, and those are not photos.
    private static func listFiles(in folder: URL, cardRoot: URL) throws -> [Entry] {
        let rootPath = cardRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CardImportError.cardUnreadable(cardRoot.lastPathComponent)
        }
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            entries.append(Entry(
                url: resolved,
                relativePath: String(resolved.path.dropFirst(rootPath.count + 1)),
                fileSize: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate
            ))
        }
        return entries
    }
}

/// Errors that stop a card import before or during the copy (messages in French, localized).
enum CardImportError: LocalizedError, Equatable {
    case notACameraCard(String)
    case cardUnreadable(String)
    case emptyCard(String)
    case destinationUnavailable(String)
    case notEnoughSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .notACameraCard(let name):
            String(localized: "« \(name) » ne contient pas de dossier DCIM : ce n'est pas une carte d'appareil photo. Choisissez la carte elle-même.")
        case .cardUnreadable(let name):
            String(localized: "Impossible de lire la carte « \(name) ». Vérifiez qu'elle est bien insérée.")
        case .emptyCard(let name):
            String(localized: "Aucune photo ni vidéo sur la carte « \(name) ».")
        case .destinationUnavailable(let name):
            String(localized: "L'emplacement « \(name) » n'est pas disponible. Choisissez-en un autre.")
        case .notEnoughSpace(let needed, let available):
            String(localized: "Pas assez de place à cet emplacement : il faut \(needed.formatted(.byteCount(style: .file))), il reste \(available.formatted(.byteCount(style: .file))).")
        }
    }
}
