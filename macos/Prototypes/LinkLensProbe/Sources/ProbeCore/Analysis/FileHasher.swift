import CryptoKit
import Foundation

/// SHA-256 of a file, read in 1 MB chunks (never loads a 25 MB RAW into memory at once).
/// The file is opened read-only.
public enum FileHasher {
    static let chunkSize = 1 << 20

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
