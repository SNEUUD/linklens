import CryptoKit
import Foundation

/// A file copied from the card and checked.
struct CopiedFile: Sendable, Equatable {
    /// Path on the card, e.g. "DCIM/100MSDCF/DSC00001.ARW".
    var sourcePath: String
    var destination: URL
    /// SHA-256 of the original, equal to the one of the copy (hexadecimal).
    var sha256: String
}

/// Why one file could not be copied safely. The original on the card is never touched.
enum CopyFailure: Error, Sendable, Equatable {
    /// The copy was written but its fingerprint differs from the original's: it was deleted.
    case mismatch
    case readFailed(String)
    case writeFailed(String)

    var message: String {
        switch self {
        case .mismatch:
            String(localized: "La copie n'est pas identique à l'original (empreinte différente).")
        case .readFailed(let reason):
            String(localized: "Lecture impossible sur la carte : \(reason)")
        case .writeFailed(let reason):
            String(localized: "Écriture impossible : \(reason)")
        }
    }
}

/// Copies one file and proves the copy is identical, with SHA-256 fingerprints (CryptoKit).
///
/// 1. The original is read once, by blocks: each block is added to its fingerprint and written to a
///    hidden temporary file next to the final one (created only if no file has that name).
/// 2. The copy is flushed to the disk, then read back while bypassing the system cache, so its
///    fingerprint comes from what the disk really holds.
/// 3. Different fingerprints: the copy is deleted and `CopyFailure.mismatch` is thrown. Identical:
///    the copy gets its final name, never replacing an existing file, and the original's dates.
enum VerifiedCopier {
    static let blockSize = 4 * 1024 * 1024

    /// - Parameters:
    ///   - afterWrite: runs on the temporary copy before it is checked. Lets the tests simulate a faulty disk.
    ///   - onBytes: called after each block written, with its size (for the progress bar).
    static func copy(
        _ source: URL,
        into folder: URL,
        name: String,
        afterWrite: (URL) throws -> Void = { _ in },
        onBytes: (Int) async -> Void = { _ in }
    ) async throws -> (url: URL, sha256: String) {
        let temporary = folder.appending(path: ".\(name).linklens-\(UUID().uuidString).tmp")
        // Removes the temporary file on every exit path; after the final `moveItem` it no longer exists.
        defer { try? FileManager.default.removeItem(at: temporary) }

        let sourceHash = try await write(source, to: temporary, onBytes: onBytes)
        try Task.checkCancellation()
        do {
            try afterWrite(temporary)
        } catch {
            throw CopyFailure.writeFailed(error.localizedDescription)
        }
        let copyHash: String
        do {
            copyHash = try sha256(of: temporary, bypassingCache: true)
        } catch {
            throw CopyFailure.readFailed(error.localizedDescription)
        }
        guard copyHash == sourceHash else {
            throw CopyFailure.mismatch
        }

        let final: URL
        do {
            final = try PhotoExporter.moveWithoutReplacing(
                temporary,
                into: folder,
                plannedName: name,
                base: (name as NSString).deletingPathExtension,
                fileExtension: (name as NSString).pathExtension
            )
        } catch {
            throw CopyFailure.writeFailed(error.localizedDescription)
        }
        // Same dates as on the card (best effort: a copy with today's date is still a good copy).
        if let dates = try? FileManager.default.attributesOfItem(atPath: source.path) {
            let kept = dates.filter { $0.key == .modificationDate || $0.key == .creationDate }
            try? FileManager.default.setAttributes(kept, ofItemAtPath: final.path)
        }
        return (final, sourceHash)
    }

    /// Reads `source` block by block, writes each block to `temporary`, returns the original's SHA-256.
    private static func write(_ source: URL, to temporary: URL, onBytes: (Int) async -> Void) async throws -> String {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw CopyFailure.readFailed(error.localizedDescription)
        }
        defer { try? input.close() }

        // `O_EXCL`: fails if a file of that name exists, so nothing is ever overwritten.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw CopyFailure.writeFailed(String(cString: strerror(errno)))
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let block: Data
            do {
                block = try input.read(upToCount: blockSize) ?? Data()
            } catch {
                throw CopyFailure.readFailed(error.localizedDescription)
            }
            if block.isEmpty { break }
            hasher.update(data: block)
            do {
                try output.write(contentsOf: block)
            } catch {
                throw CopyFailure.writeFailed(error.localizedDescription)
            }
            await onBytes(block.count)
        }
        do {
            try output.synchronize() // the data is on the disk, not only in memory
        } catch {
            throw CopyFailure.writeFailed(error.localizedDescription)
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 of a file, in hexadecimal. `bypassingCache` reads from the disk itself, not from the
    /// copy the system may still hold in memory.
    static func sha256(of url: URL, bypassingCache: Bool = false) throws -> String {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if bypassingCache {
            _ = fcntl(descriptor, F_NOCACHE, 1)
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var hasher = SHA256()
        while let block = try input.read(upToCount: blockSize), !block.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: block)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
