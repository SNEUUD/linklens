import Foundation

struct CullingProgress: Sendable, Equatable {
    var galleryId: UUID
    var completed: Int
    var total: Int

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

/// Number of photos per verdict after a run.
struct CullingSummary: Sendable, Equatable {
    var keep = 0
    var review = 0
    var reject = 0
    /// Photos that could not be read (counted in `review` too).
    var failed = 0
}

/// F3: explained AI sorting of a gallery (Garder / À revoir / Rejeter, always with the reasons).
///
/// Steps: bookmark → parallel analysis → chronological order → bursts → verdicts → batches written
/// by `LibraryStore`. The files are only read. If cancelled during the analysis, nothing is written
/// and the previous verdicts stay as they were.
struct GalleryCuller: Sendable {
    let store: LibraryStore
    var thresholds = CullingThresholds()
    /// Photos analysed at the same time.
    var concurrency = ProcessInfo.processInfo.activeProcessorCount
    var batchSize = 200

    @concurrent
    func cullGallery(
        id galleryId: UUID,
        onProgress: @MainActor @Sendable (CullingProgress) -> Void = { _ in }
    ) async throws -> CullingSummary {
        let contents = try await store.cullingContents(galleryId: galleryId)
        // The bookmark saved at indexing time reopens the folder, even after the app restarted.
        let folder = try FolderBookmark.resolve(contents.folderBookmark)
        guard folder.startAccessingSecurityScopedResource() else {
            throw LibraryError.accessDenied(contents.name)
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw LibraryError.folderNotFound(contents.folderPath)
        }

        let (analyses, failures) = await analyze(contents.photos, in: folder, galleryId: galleryId, onProgress: onProgress)
        try Task.checkCancellation()

        let results = Classifier.classifyGallery(analyses: analyses, failedPhotoIds: failures, thresholds: thresholds)
        // From here on the run is not cancelled any more: a few quick batches, so verdicts stay consistent.
        let analyzedAt = Date()
        for start in stride(from: 0, to: results.count, by: batchSize) {
            try await store.saveCulling(Array(results[start..<min(start + batchSize, results.count)]), analyzedAt: analyzedAt)
        }
        try await store.finishCulling(galleryId: galleryId)

        var summary = CullingSummary()
        for result in results {
            switch result.verdict {
            case .keep: summary.keep += 1
            case .review, .unknown: summary.review += 1
            case .reject: summary.reject += 1
            }
        }
        summary.failed = failures.count
        return summary
    }

    /// Analyses the photos in parallel, at most `concurrency` at a time.
    /// One unreadable photo never stops the run: its id is returned in `failures`.
    private func analyze(
        _ photos: [PhotoReference],
        in folder: URL,
        galleryId: UUID,
        onProgress: @MainActor @Sendable (CullingProgress) -> Void
    ) async -> (analyses: [PhotoAnalysis], failures: [UUID]) {
        // Result of one task: success or failure, never a thrown error.
        enum Outcome: Sendable {
            case success(PhotoAnalysis)
            case failure(UUID)
        }

        let thresholds = thresholds
        let limit = max(1, concurrency)
        var analyses: [PhotoAnalysis] = []
        var failures: [UUID] = []
        await onProgress(CullingProgress(galleryId: galleryId, completed: 0, total: photos.count))

        // A task group runs child tasks in parallel and collects their results as they finish:
        // like `Promise.all`, but here with a limit (a new photo starts each time one ends).
        // Cancelling the parent task cancels every child.
        await withTaskGroup(of: Outcome.self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < photos.count else { return }
                let photo = photos[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        return .success(try await PhotoAnalyzer.analyze(photo, in: folder, thresholds: thresholds))
                    } catch {
                        return .failure(photo.id)
                    }
                }
            }

            for _ in 0..<limit { startNext() }
            while let outcome = await group.next() {
                switch outcome {
                case .success(let analysis): analyses.append(analysis)
                case .failure(let photoId): failures.append(photoId)
                }
                await onProgress(CullingProgress(
                    galleryId: galleryId, completed: analyses.count + failures.count, total: photos.count
                ))
                if !Task.isCancelled { startNext() }
            }
        }
        return (analyses, failures)
    }
}
