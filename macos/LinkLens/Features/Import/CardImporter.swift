import Foundation

/// Everything a card import needs, chosen in the import sheet.
struct CardImportRequest: Sendable {
    var card: CardContents
    /// Location chosen for the gallery (e.g. "Images/LinkLens"): the year folder is created inside.
    var destination: URL
    var sessionName: String
    /// Day of the session, in the folder name.
    var sessionDate: Date
}

struct CardImportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case copying
        case indexing
    }

    var phase: Phase
    var completedFiles: Int
    var totalFiles: Int
    var completedBytes: Int64
    var totalBytes: Int64
    /// Name of the file being copied.
    var currentFile: String?

    var fraction: Double {
        switch phase {
        case .copying: totalBytes == 0 ? 0 : Double(completedBytes) / Double(totalBytes)
        case .indexing: totalFiles == 0 ? 0 : Double(completedFiles) / Double(totalFiles)
        }
    }
}

struct CardImportFailure: Sendable, Equatable {
    /// Path on the card.
    var relativePath: String
    var reason: CopyFailure
}

/// Outcome of a card import, shown at the end.
struct CardImportReport: Sendable, Equatable {
    var cardName: String
    var sessionFolder: URL
    /// "2026/2026-10-14 Mariage Julie & Tom", relative to the chosen location.
    var sessionPath: String
    var copiedFiles: [CopiedFile]
    var failures: [CardImportFailure]
    /// Files of the card that were not copied (unsupported format).
    var notImported: [String]
    var galleryId: UUID?
    /// The files are copied and checked, but the gallery could not be created.
    var indexingError: String?

    /// « Vous pouvez formater la carte » only when every file of the card is copied and identical.
    var canFormatCard: Bool {
        !copiedFiles.isEmpty && failures.isEmpty && notImported.isEmpty
    }
}

/// F1: copies a camera card into a new gallery, checks every copy, then indexes it like F2.
///
/// - Only reads the card: it is never written to, nothing on it is renamed or deleted.
/// - Writes only inside a new session folder, `AAAA/AAAA-MM-JJ Nom de séance/`, never replacing a file.
/// - One file whose copy differs from the original is deleted from the destination and listed in
///   `failures`; the other files go on.
/// - Cancelled: every file and folder this import created is removed from the destination
///   (the card still holds everything), and `CancellationError` is thrown.
struct CardImporter: Sendable {
    let store: LibraryStore
    var indexingBatchSize = 200
    /// Test seam, see `VerifiedCopier.copy(afterWrite:)`.
    var afterWrite: @Sendable (URL) throws -> Void = { _ in }

    @concurrent
    func importCard(
        _ request: CardImportRequest,
        onProgress: @MainActor @Sendable (CardImportProgress) -> Void = { _ in }
    ) async throws -> CardImportReport {
        let card = request.card
        guard !card.files.isEmpty else {
            throw CardImportError.emptyCard(card.name)
        }
        // The folder pickers already granted access for this launch; a URL from a bookmark also
        // needs `startAccessing…`. Both cases are covered by calling it and stopping only if it worked.
        let isAccessingCard = card.root.startAccessingSecurityScopedResource()
        defer { if isAccessingCard { card.root.stopAccessingSecurityScopedResource() } }
        let isAccessingDestination = request.destination.startAccessingSecurityScopedResource()
        defer { if isAccessingDestination { request.destination.stopAccessingSecurityScopedResource() } }

        try checkDestination(request.destination, needs: card.totalBytes)
        var created = CreatedItems()
        let (sessionFolder, sessionPath) = try makeSessionFolder(for: request, created: &created)

        do {
            let report = try await copyFiles(of: card, into: sessionFolder, sessionPath: sessionPath, created: &created, onProgress: onProgress)
            guard !report.copiedFiles.isEmpty else {
                created.removeAll() // nothing copied: no empty folder left behind
                return report
            }
            return try await index(report, onProgress: onProgress)
        } catch is CancellationError {
            created.removeAll()
            throw CancellationError()
        }
    }

    private func checkDestination(_ destination: URL, needs bytes: Int64) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CardImportError.destinationUnavailable(destination.lastPathComponent)
        }
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < bytes {
            throw CardImportError.notEnoughSpace(needed: bytes, available: available)
        }
    }

    /// Creates `AAAA/AAAA-MM-JJ Nom/`, or "… (2)" if that folder exists already: an import never
    /// writes into an existing session folder.
    private func makeSessionFolder(for request: CardImportRequest, created: inout CreatedItems) throws -> (URL, String) {
        let names = ImportLayout.folderNames(date: request.sessionDate, sessionName: request.sessionName)
        let yearFolder = request.destination.appending(path: names.year, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: yearFolder, withIntermediateDirectories: false)
            created.folders.append(yearFolder)
        } catch CocoaError.fileWriteFileExists {
            // The year folder of an earlier import: kept as it is.
        } catch {
            throw CardImportError.destinationUnavailable(request.destination.lastPathComponent)
        }
        for number in 1...1_000 {
            let name = ImportLayout.numberedFolderName(names.session, number: number)
            let folder = yearFolder.appending(path: name, directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                created.folders.append(folder)
                return (folder, "\(names.year)/\(name)")
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CardImportError.destinationUnavailable(names.session)
    }

    private func copyFiles(
        of card: CardContents,
        into sessionFolder: URL,
        sessionPath: String,
        created: inout CreatedItems,
        onProgress: @MainActor @Sendable (CardImportProgress) -> Void
    ) async throws -> CardImportReport {
        let names = ImportLayout.destinationNames(for: card.files.map(\.relativePath))
        var progress = CardImportProgress(
            phase: .copying, completedFiles: 0, totalFiles: card.files.count,
            completedBytes: 0, totalBytes: card.totalBytes, currentFile: nil
        )
        var copied: [CopiedFile] = []
        var failures: [CardImportFailure] = []

        for (file, name) in zip(card.files, names) {
            try Task.checkCancellation()
            progress.currentFile = (file.relativePath as NSString).lastPathComponent
            await onProgress(progress)
            let bytesBefore = progress.completedBytes
            do {
                let result = try await VerifiedCopier.copy(file.url, into: sessionFolder, name: name, afterWrite: afterWrite) { count in
                    progress.completedBytes += Int64(count)
                    await onProgress(progress)
                }
                created.files.append(result.url)
                copied.append(CopiedFile(sourcePath: file.relativePath, destination: result.url, sha256: result.sha256))
            } catch let failure as CopyFailure {
                failures.append(CardImportFailure(relativePath: file.relativePath, reason: failure))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(CardImportFailure(relativePath: file.relativePath, reason: .writeFailed(error.localizedDescription)))
            }
            // A failed file still counts as done, with its full size, so the bar reaches the end.
            progress.completedBytes = bytesBefore + file.fileSize
            progress.completedFiles += 1
        }
        progress.currentFile = nil
        await onProgress(progress)

        return CardImportReport(
            cardName: card.name,
            sessionFolder: sessionFolder,
            sessionPath: sessionPath,
            copiedFiles: copied,
            failures: failures,
            notImported: card.notImported,
            galleryId: nil,
            indexingError: nil
        )
    }

    /// Indexes the session folder exactly like F2 (bookmark, scan, metadata, batches).
    private func index(
        _ report: CardImportReport,
        onProgress: @MainActor @Sendable (CardImportProgress) -> Void
    ) async throws -> CardImportReport {
        var report = report
        let indexer = FolderIndexer(store: store, batchSize: indexingBatchSize, includeVideos: true)
        do {
            let result = try await indexer.indexFolder(at: report.sessionFolder) { indexing in
                onProgress(CardImportProgress(
                    phase: .indexing, completedFiles: indexing.completed, totalFiles: indexing.total,
                    completedBytes: 0, totalBytes: 0, currentFile: nil
                ))
            }
            switch result {
            case .indexed(let galleryId, _), .alreadyIndexed(let galleryId):
                report.galleryId = galleryId
            }
            if let galleryId = report.galleryId {
                // The fingerprints checked during the copy spare the duplicate search (F5) from reading
                // these files again. Files are flat in the session folder: the path is the file name.
                let fingerprints = Dictionary(
                    report.copiedFiles.map { ($0.destination.lastPathComponent, $0.sha256) },
                    uniquingKeysWith: { first, _ in first }
                )
                // This app created the folder in a location chosen read-write: allowed to trash duplicates there.
                let writeBookmark = try? FolderBookmark.createReadWrite(for: report.sessionFolder)
                try? await store.saveImportedFingerprints(fingerprints, writeBookmark: writeBookmark, galleryId: galleryId)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The copies are checked and stay on the disk; only the gallery is missing.
            report.indexingError = error.localizedDescription
        }
        return report
    }
}

/// What an import created in the destination, to undo it when cancelled.
private struct CreatedItems {
    var files: [URL] = []
    /// Year and session folders this import created (an existing year folder is not listed).
    var folders: [URL] = []

    /// Removes the files, then the folders if they are empty (deepest first). Nothing else is touched.
    func removeAll() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        for folder in folders.reversed() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
