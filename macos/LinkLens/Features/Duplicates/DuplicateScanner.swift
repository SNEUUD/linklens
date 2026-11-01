import Foundation

struct DuplicateScanProgress: Sendable, Equatable {
    var completedFiles: Int
    var totalFiles: Int
    var completedBytes: Int64
    var totalBytes: Int64

    var fraction: Double { totalBytes == 0 ? 0 : Double(completedBytes) / Double(totalBytes) }
}

/// Result of a search: the groups and what could not be checked.
struct DuplicateReport: Sendable, Equatable {
    var groups: [DuplicateGroup]
    /// Galleries whose folder could not be opened (disk unplugged, folder moved): their files without
    /// a fingerprint were not compared.
    var unreachableGalleries: [String]
    /// Files that could not be read (deleted outside the app, damaged disk…).
    var unreadableFiles: Int

    var recoverableBytes: Int64 { DuplicateFinder.recoverableBytes(groups) }
}

/// F5: finds the exact duplicates of the whole catalogue.
///
/// 1. Reads every file of the catalogue from `LibraryStore` (no file is opened yet).
/// 2. Computes the missing SHA-256 fingerprints, only for files whose size matches another file's,
///    a few at a time. Each batch is saved: a cancelled search resumes where it stopped.
/// 3. Groups identical files. Nothing is ever written to the photo folders, which are only read.
struct DuplicateScanner: Sendable {
    let store: LibraryStore
    /// Files read at the same time. Hashing is limited by the disk, not the processor: a few suffice.
    var concurrency = 4
    var batchSize = 100

    @concurrent
    func scan(onProgress: @MainActor @Sendable (DuplicateScanProgress) -> Void = { _ in }) async throws -> DuplicateReport {
        let catalogue = try await store.duplicateCatalogue()
        let toFingerprint = DuplicateFinder.filesToFingerprint(catalogue.files)

        // Open the folders that hold files to read, each once, for the whole search.
        let neededGalleries = Set(toFingerprint.map(\.galleryId))
        var folders: [UUID: URL] = [:]
        var unreachable: [String] = []
        for gallery in catalogue.galleries where neededGalleries.contains(gallery.id) {
            if let folder = Self.openForReading(gallery) {
                folders[gallery.id] = folder
            } else {
                unreachable.append(gallery.name)
            }
        }
        defer {
            for folder in folders.values { folder.stopAccessingSecurityScopedResource() }
        }

        let reachable = toFingerprint.filter { folders[$0.galleryId] != nil }
        let unreadable = try await fingerprint(reachable, folders: folders, onProgress: onProgress)

        let updated = try await store.duplicateCatalogue()
        return DuplicateReport(
            groups: DuplicateFinder.groups(updated.files),
            unreachableGalleries: unreachable.sorted(),
            unreadableFiles: unreadable
        )
    }

    /// Hashes the files in parallel (at most `concurrency` at a time) and saves the fingerprints by batches.
    /// Returns the number of files that could not be read.
    private func fingerprint(
        _ files: [DuplicateCopy],
        folders: [UUID: URL],
        onProgress: @MainActor @Sendable (DuplicateScanProgress) -> Void
    ) async throws -> Int {
        var progress = DuplicateScanProgress(
            completedFiles: 0, totalFiles: files.count,
            completedBytes: 0, totalBytes: files.reduce(0) { $0 + $1.fileSize }
        )
        await onProgress(progress)
        guard !files.isEmpty else { return 0 }

        var pending: [UUID: String] = [:]
        var unreadable = 0
        let limit = max(1, concurrency)

        // Same pattern as the AI sorting (F3): a task group with a limit, a new file starting each time
        // one ends. `(UUID, String?)` is a tuple, like `[id, hash]` returned from a TypeScript function.
        await withTaskGroup(of: (UUID, String?).self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < files.count else { return }
                let file = files[nextIndex]
                nextIndex += 1
                // Always there (`scan` only passes files of opened folders); a missing one counts as unreadable.
                let url = folders[file.galleryId]?.appending(path: file.relativePath)
                group.addTask {
                    (file.photoId, url.flatMap { try? VerifiedCopier.sha256(of: $0) })
                }
            }

            for _ in 0..<limit { startNext() }
            var sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.photoId, $0.fileSize) })
            while let (photoId, sha256) = await group.next() {
                if let sha256 {
                    pending[photoId] = sha256
                } else if !Task.isCancelled {
                    unreadable += 1
                }
                progress.completedFiles += 1
                progress.completedBytes += sizes.removeValue(forKey: photoId) ?? 0
                await onProgress(progress)
                if pending.count >= batchSize {
                    try? await store.saveFingerprints(pending)
                    pending.removeAll()
                }
                if !Task.isCancelled { startNext() }
            }
        }
        // What was computed before a cancellation is kept too.
        if !pending.isEmpty {
            try await store.saveFingerprints(pending)
        }
        try Task.checkCancellation()
        return unreadable
    }

    /// Opens a gallery folder through its bookmark. Nil if it cannot be reached now.
    static func openForReading(_ gallery: GalleryLocation) -> URL? {
        guard let folder = try? FolderBookmark.resolve(gallery.folderBookmark),
              folder.startAccessingSecurityScopedResource()
        else { return nil }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            folder.stopAccessingSecurityScopedResource()
            return nil
        }
        return folder
    }
}
