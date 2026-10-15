import Foundation

/// A gallery as the duplicate search sees it: where its folder is and how to open it.
struct GalleryLocation: Sendable, Equatable {
    var id: UUID
    var name: String
    var folderPath: String
    var createdAt: Date
    var folderBookmark: Data
    var writeBookmark: Data?
}

/// One file of the catalogue (photo or video), as a `Sendable` copy read by `LibraryStore`.
struct DuplicateCopy: Sendable, Equatable, Identifiable {
    var photoId: UUID
    var galleryId: UUID
    var galleryName: String
    var galleryCreatedAt: Date
    var relativePath: String
    var fileSize: Int64
    /// Nil while the fingerprint has not been computed.
    var sha256: String?
    var verdict: CullingVerdict?

    var id: UUID { photoId }
    var fileName: String { (relativePath as NSString).lastPathComponent }
}

/// Why a copy is proposed as the one to keep. Only the rule that actually decided is given.
enum KeepReason: Sendable, Equatable {
    /// The only copy (or among the only ones) the AI sorting proposed to keep.
    case sortedKeep
    /// In the gallery created first: usually the original import.
    case oldestGallery
    /// Same gallery, or same date: the shortest name, e.g. "DSC00001.ARW" rather than "DSC00001 (2).ARW".
    case simplestName

    var label: String {
        switch self {
        case .sortedKeep: String(localized: "Triée « Garder »")
        case .oldestGallery: String(localized: "Galerie la plus ancienne")
        case .simplestName: String(localized: "Nom le plus simple")
        }
    }
}

struct KeepProposal: Sendable, Equatable {
    var photoId: UUID
    var reason: KeepReason
}

/// Files that are identical byte for byte: same size and same SHA-256.
struct DuplicateGroup: Sendable, Equatable, Identifiable {
    var sha256: String
    var fileSize: Int64
    /// Oldest gallery first, then by name.
    var copies: [DuplicateCopy]
    var proposal: KeepProposal

    var id: String { sha256 }
    /// Space freed by keeping a single copy.
    var extraBytes: Int64 { fileSize * Int64(copies.count - 1) }
}

/// F5: exact duplicates over the whole catalogue. Pure logic, kept apart from SwiftData and the files
/// so it can be tested.
enum DuplicateFinder {
    /// Files worth fingerprinting: no fingerprint yet, and another file has exactly the same size.
    /// A file with a unique size cannot have an identical copy, so it is never read.
    static func filesToFingerprint(_ files: [DuplicateCopy]) -> [DuplicateCopy] {
        let sizes = sharedSizes(files)
        return files.filter { $0.sha256 == nil && sizes.contains($0.fileSize) }
    }

    /// Groups of at least two identical files, the biggest saving first.
    static func groups(_ files: [DuplicateCopy]) -> [DuplicateGroup] {
        let sizes = sharedSizes(files)
        // Grouped by size and fingerprint: `Dictionary(grouping:by:)` is like lodash's `groupBy`.
        let bySize = Dictionary(grouping: files.filter { $0.sha256 != nil && sizes.contains($0.fileSize) }) { file in
            FileKey(size: file.fileSize, sha256: file.sha256 ?? "")
        }
        return bySize.compactMap { key, copies -> DuplicateGroup? in
            guard copies.count >= 2 else { return nil }
            let sorted = copies.sorted(by: displayOrder)
            return DuplicateGroup(sha256: key.sha256, fileSize: key.size, copies: sorted, proposal: proposal(for: sorted))
        }
        .sorted { a, b in
            if a.extraBytes != b.extraBytes { return a.extraBytes > b.extraBytes }
            return a.copies[0].relativePath.localizedStandardCompare(b.copies[0].relativePath) == .orderedAscending
        }
    }

    /// The copy to keep, by a simple rule the user can read:
    /// 1. the copy sorted « Garder », if not all of them are;
    /// 2. otherwise the copy in the oldest gallery, if not all of them are in it;
    /// 3. otherwise the simplest name (shortest, then alphabetical).
    static func proposal(for copies: [DuplicateCopy]) -> KeepProposal {
        precondition(!copies.isEmpty)
        let sortedKeep = copies.filter { $0.verdict == .keep }
        if !sortedKeep.isEmpty, sortedKeep.count < copies.count {
            return KeepProposal(photoId: oldestThenSimplest(sortedKeep).photoId, reason: .sortedKeep)
        }
        let oldestDate = copies.map(\.galleryCreatedAt).min()
        let inOldest = copies.filter { $0.galleryCreatedAt == oldestDate }
        if inOldest.count < copies.count {
            return KeepProposal(photoId: simplest(inOldest).photoId, reason: .oldestGallery)
        }
        return KeepProposal(photoId: simplest(copies).photoId, reason: .simplestName)
    }

    /// Total space freed when one copy of each group is kept.
    static func recoverableBytes(_ groups: [DuplicateGroup]) -> Int64 {
        groups.reduce(0) { $0 + $1.extraBytes }
    }

    // MARK: - Helpers

    private struct FileKey: Hashable {
        var size: Int64
        var sha256: String
    }

    /// Sizes held by at least two files. Empty files are left out: they are not photos.
    private static func sharedSizes(_ files: [DuplicateCopy]) -> Set<Int64> {
        var counts: [Int64: Int] = [:]
        for file in files where file.fileSize > 0 {
            counts[file.fileSize, default: 0] += 1
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    private static func oldestThenSimplest(_ copies: [DuplicateCopy]) -> DuplicateCopy {
        let oldestDate = copies.map(\.galleryCreatedAt).min()
        return simplest(copies.filter { $0.galleryCreatedAt == oldestDate })
    }

    private static func simplest(_ copies: [DuplicateCopy]) -> DuplicateCopy {
        copies.min(by: isSimpler)!
    }

    /// Shortest path first, then alphabetical: "DSC1.ARW" before "DSC1 (2).ARW" and "Jour 2/DSC1.ARW".
    private static func isSimpler(_ a: DuplicateCopy, _ b: DuplicateCopy) -> Bool {
        if a.relativePath.count != b.relativePath.count { return a.relativePath.count < b.relativePath.count }
        return a.relativePath < b.relativePath
    }

    /// Oldest gallery first, then the simplest name, so the list reads in the order of the rule.
    private static func displayOrder(_ a: DuplicateCopy, _ b: DuplicateCopy) -> Bool {
        if a.galleryCreatedAt != b.galleryCreatedAt { return a.galleryCreatedAt < b.galleryCreatedAt }
        return isSimpler(a, b)
    }
}
