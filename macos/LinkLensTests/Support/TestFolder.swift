import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import LinkLens

/// A temporary folder filled by a test, removed with `remove()`.
struct TestFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "LinkLensTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A folder that already exists (made by the code under test), to read with `snapshot()`.
    init(existing url: URL) {
        self.url = url
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func writeFile(_ relativePath: String, contents: String = "not a photo") throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// Writes a small real JPEG, with an EXIF capture date when given ("2026:09:20 14:40:57").
    @discardableResult
    func writeJPEG(_ relativePath: String, width: Int = 64, height: Int = 48, exifDate: String? = nil) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let exifDate {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return file
    }

    /// Every file of the folder (hidden ones included) with its size, modification date and SHA-256.
    /// Two equal snapshots mean nothing was added, removed, renamed or modified.
    func snapshot() throws -> [String: FileFingerprint] {
        let root = url.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var result: [String: FileFingerprint] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys))
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            guard values.isRegularFile == true else {
                result[relative + "/"] = FileFingerprint(size: 0, modifiedAt: nil, sha256: "")
                continue
            }
            let digest = SHA256.hash(data: try Data(contentsOf: file))
            result[relative] = FileFingerprint(
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate,
                sha256: digest.map { String(format: "%02x", $0) }.joined()
            )
        }
        return result
    }
}

struct FileFingerprint: Equatable {
    var size: Int
    var modifiedAt: Date?
    var sha256: String
}

/// A fresh SwiftData database in memory, isolated from the app's real catalogue.
func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Gallery.self, Photo.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}
