import Foundation

struct DetailsProgress: Sendable, Equatable {
    var galleryId: UUID
    var completed: Int
    var total: Int
}

/// Reads again what the inspector needs for photos analysed before it was stored: camera and settings
/// (EXIF), subject box (Vision saliency) and burnt highlights / blocked shadows. Videos get their length.
///
/// The same measurements as the analysis (`PhotoAnalyzer`), on the same preview, so the box and the
/// exposure match what the verdict was based on. Only `LibraryStore.saveDetails` writes: the verdicts,
/// reasons, bursts and the user's choices are never touched. The files are only read.
/// Cancelling keeps what was already saved (batch by batch): the next run goes on from there.
struct DetailsBackfiller: Sendable {
    let store: LibraryStore
    var thresholds = CullingThresholds()
    /// Photos read at the same time: half the cores, so the app stays responsive while it runs.
    var concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    var batchSize = 24

    /// Fills in the missing details of one gallery and returns how many photos were done.
    /// Throws when the folder cannot be opened (disk unplugged, F9): nothing is written then.
    @concurrent
    func fillDetails(
        galleryId: UUID,
        onProgress: @MainActor @Sendable (DetailsProgress) -> Void = { _ in }
    ) async throws -> Int {
        let work = try await store.detailsWork(galleryId: galleryId)
        guard !work.items.isEmpty else { return 0 }
        // Never tries to mount a disk that is not there.
        let folder = try FolderBookmark.resolveWithoutMounting(work.folderBookmark).url
        guard folder.startAccessingSecurityScopedResource() else {
            throw LibraryError.accessDenied(folder.lastPathComponent)
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw LibraryError.folderNotFound(folder.path)
        }

        let total = work.items.count
        var completed = 0
        await onProgress(DetailsProgress(galleryId: galleryId, completed: 0, total: total))
        let thresholds = thresholds
        let limit = max(1, concurrency)
        for start in stride(from: 0, to: total, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(work.items[start..<min(start + batchSize, total)])
            // A task group runs the photos of the batch in parallel, `limit` at a time (see `GalleryCuller`).
            let details = await withTaskGroup(of: PhotoDetails.self) { group in
                var results: [PhotoDetails] = []
                var next = 0
                func startNext() {
                    guard next < batch.count else { return }
                    let item = batch[next]
                    next += 1
                    group.addTask { await Self.read(item, in: folder, thresholds: thresholds) }
                }
                for _ in 0..<limit { startNext() }
                while let result = await group.next() {
                    results.append(result)
                    if !Task.isCancelled { startNext() }
                }
                return results
            }
            // A batch cut short by a cancellation is not saved: its photos are read again next time.
            try Task.checkCancellation()
            // Disk unplugged during the batch (F9): its files only looked unreadable. Not saved either.
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw LibraryError.folderNotFound(folder.path)
            }
            try await store.saveDetails(details)
            completed += details.count
            await onProgress(DetailsProgress(galleryId: galleryId, completed: completed, total: total))
        }
        return completed
    }

    /// One photo or video. An unreadable file still gets a date, so it is not read again at every launch.
    static func read(_ item: DetailsWork.Item, in folder: URL, thresholds: CullingThresholds) async -> PhotoDetails {
        let url = folder.appending(path: item.relativePath)
        var details = PhotoDetails(photoId: item.photoId, readAt: .now)
        switch item.mediaKind {
        case .video:
            details.videoDuration = await VideoReader.metadata(url: url).duration
        case .photo, .unknown:
            let metadata = PhotoMetadataReader.read(url: url)
            if metadata != .unknown { details.capture = metadata.capture }
            details.measured = try? await measure(url: url, thresholds: thresholds)
        }
        return details
    }

    /// Subject box and exposure, measured exactly as `PhotoAnalyzer` does.
    static func measure(url: URL, thresholds: CullingThresholds) async throws -> PhotoDetails.Measured {
        let image = try PreviewLoader.load(url: url)
        let subjectBox = try await VisionAnalyzer.subjectBox(of: image)
        let exposure = Exposure.measure(try GrayImage(image: image, longSide: thresholds.analysisLongSide))
        return PhotoDetails.Measured(
            subjectBox: subjectBox,
            highlightClipping: exposure.highlightClipping,
            shadowClipping: exposure.shadowClipping
        )
    }
}
