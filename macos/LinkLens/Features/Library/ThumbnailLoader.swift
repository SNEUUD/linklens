import CoreGraphics
import Foundation
import os

/// What the loader needs to know about a photo: a plain `Sendable` copy of `Photo`.
struct ThumbnailRequest: Sendable, Hashable {
    var photoId: UUID
    var relativePath: String
}

extension Photo {
    var thumbnailRequest: ThumbnailRequest {
        ThumbnailRequest(photoId: id, relativePath: relativePath)
    }
}

/// Serves the thumbnails of the displayed gallery and generates the missing ones in the background.
///
/// - Memory (`NSCache`) → disk (`ThumbnailCache`) → generation from the photo file, in that order.
/// - Generation runs a few photos at a time. Thumbnails a grid cell is waiting for jump to the
///   front of the queue; the others follow in grid order, so the whole gallery ends up cached.
/// - The folder is opened once, through its bookmark, while the gallery is shown, and only read.
///   If it cannot be opened (disk unplugged, F9), only the cached thumbnails are shown.
///
/// `@MainActor` means every method runs on the main thread, like all the code of a React component:
/// the queue needs no lock. The slow work (reading files) is sent elsewhere by the `@concurrent` functions.
@MainActor
final class ThumbnailLoader {
    let cache: ThumbnailCache
    let maxConcurrentGenerations: Int
    /// Opened folder of the gallery, nil when it could not be reached.
    private(set) var folder: URL?
    /// Counts the openings of the folder: a late read from before an unplug and replug must not
    /// close the folder opened since.
    private var folderOpening = 0

    /// Decoded thumbnails, dropped by the system when memory runs low (about 700 KB each).
    private let memory = NSCache<NSUUID, CGImage>()
    private var queue: [ThumbnailRequest] = []
    private var queuedIds: Set<UUID> = []
    private var runningIds: Set<UUID> = []
    private var failedIds: Set<UUID> = []
    /// Callers waiting for a thumbnail being generated (the `await` of a grid cell).
    private var waiters: [UUID: [CheckedContinuation<CGImage?, Never>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Large previews of the viewer, most recent last (a few only: about 7 MB each).
    private var previews: [(photoId: UUID, image: CGImage)] = []
    /// The last photo read at full resolution (viewer zoom).
    private var fullSize: (photoId: UUID, image: CGImage)?
    private var isStopped = false
    private var generatedCount = 0
    private var busySince: ContinuousClock.Instant?

    private nonisolated static let logger = Logger(subsystem: "fr.chriscrepin.linklens", category: "thumbnails")

    init(cache: ThumbnailCache = .standard, maxConcurrentGenerations: Int = 4) {
        self.cache = cache
        self.maxConcurrentGenerations = maxConcurrentGenerations
        memory.totalCostLimit = 300 * 1024 * 1024
    }

    // MARK: - Lifecycle

    /// Opens the gallery folder for reading. Call `stop()` when the gallery is no longer shown.
    /// Calling it again is harmless: it only retries when the folder is not open yet.
    func open(folderBookmark: Data) {
        isStopped = false
        guard folder == nil else { return }
        guard let url = try? FolderBookmark.resolveWithoutMounting(folderBookmark).url, url.startAccessingSecurityScopedResource() else {
            Self.logger.notice("Gallery folder unreachable: showing cached thumbnails only")
            return
        }
        folder = url
        folderOpening += 1
    }

    /// Closes the folder and wakes up everyone still waiting (with no image).
    func stop() {
        isStopped = true
        fullSize = nil
        closeFolder()
        resumeIdleWaiters()
    }

    /// The disk was unplugged or the folder moved (F9): gives the folder back and drops the queue, so
    /// nothing keeps trying to read it. Cached thumbnails are still served; `open` starts again.
    func closeFolder() {
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
        queue.removeAll()
        queuedIds.removeAll()
        for continuation in waiters.values.joined() {
            continuation.resume(returning: nil)
        }
        waiters.removeAll()
        if runningIds.isEmpty {
            resumeIdleWaiters()
        }
    }

    // MARK: - Thumbnails

    /// Already decoded thumbnail, without waiting: lets a cell show its image on its first frame.
    func cachedThumbnail(for photoId: UUID) -> CGImage? {
        memory.object(forKey: photoId as NSUUID)
    }

    /// The thumbnail, from memory, the disk cache or freshly generated. Nil if the photo cannot be read.
    func thumbnail(for request: ThumbnailRequest) async -> CGImage? {
        let photoId = request.photoId
        if let image = cachedThumbnail(for: photoId) { return image }
        if failedIds.contains(photoId) || isStopped { return nil }

        if let image = await Self.readCached(photoId, from: cache) {
            remember(image, for: photoId)
            return image
        }
        // Generated by someone else while the disk was being read?
        if let image = cachedThumbnail(for: photoId) { return image }
        if failedIds.contains(photoId) || isStopped { return nil }

        // `withCheckedContinuation` turns a callback into an `await` (like `new Promise(resolve => …)`):
        // the continuation is resumed by `finish` once a worker has made this thumbnail.
        return await withCheckedContinuation { continuation in
            waiters[photoId, default: []].append(continuation)
            enqueue(request, urgent: true)
        }
    }

    /// Queues every photo that has no cached thumbnail yet, behind the ones the grid is waiting for.
    func prefetch(_ requests: [ThumbnailRequest]) async {
        let missing = Set(await Self.missing(requests.map(\.photoId), in: cache))
        for request in requests where missing.contains(request.photoId) {
            enqueue(request, urgent: false)
        }
    }

    /// Returns once nothing is queued or being generated (used by the tests).
    func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Viewer

    /// Large image for the viewer: the full embedded preview (1616×1080 on an A6000), read from the file.
    /// Nil when the folder is out of reach; the viewer then falls back to the thumbnail.
    func preview(for request: ThumbnailRequest) async -> CGImage? {
        if let index = previews.firstIndex(where: { $0.photoId == request.photoId }) {
            let entry = previews.remove(at: index)
            previews.append(entry)
            return entry.image
        }
        guard let folder else { return nil }
        guard let image = await Self.loadPreview(folder.appending(path: request.relativePath)) else { return nil }
        if !previews.contains(where: { $0.photoId == request.photoId }) {
            previews.append((request.photoId, image))
            if previews.count > 5 { previews.removeFirst() }
        }
        return image
    }

    /// The photo at full resolution, for the viewer's 100 % zoom. Only the last one is kept (about
    /// 96 MB for 24 megapixels). Nil for a video or when the folder is out of reach (F9).
    func fullImage(for request: ThumbnailRequest) async -> CGImage? {
        if let fullSize, fullSize.photoId == request.photoId { return fullSize.image }
        guard let folder, MediaKind(relativePath: request.relativePath) != .video else { return nil }
        guard let image = await Self.loadFullSize(folder.appending(path: request.relativePath)) else { return nil }
        fullSize = (request.photoId, image)
        return image
    }

    // MARK: - Queue

    private var isIdle: Bool { queue.isEmpty && runningIds.isEmpty }

    private func enqueue(_ request: ThumbnailRequest, urgent: Bool) {
        let photoId = request.photoId
        guard !isStopped, !runningIds.contains(photoId), !failedIds.contains(photoId) else { return }
        if queuedIds.contains(photoId) {
            guard urgent, let index = queue.firstIndex(of: request) else { return }
            queue.remove(at: index)
            queue.insert(request, at: 0)
        } else {
            queuedIds.insert(photoId)
            if urgent {
                // Last requested first: when scrolling fast, the cells on screen now come before the ones passed.
                queue.insert(request, at: 0)
            } else {
                queue.append(request)
            }
        }
        startWorkers()
    }

    private func startWorkers() {
        while runningIds.count < maxConcurrentGenerations, !queue.isEmpty {
            let request = queue.removeFirst()
            queuedIds.remove(request.photoId)
            runningIds.insert(request.photoId)
            if busySince == nil { busySince = .now }
            // `Task { }` starts async work without waiting for it (like calling an async function
            // without `await` in JavaScript). It inherits `@MainActor`, so `finish` runs on the main thread.
            Task { [folder, cache, folderOpening] in
                let outcome = await Self.generate(request, folder: folder, cache: cache)
                finish(request, outcome: outcome, folderOpening: folderOpening)
            }
        }
    }

    private func finish(_ request: ThumbnailRequest, outcome: GenerationOutcome, folderOpening: Int) {
        let photoId = request.photoId
        runningIds.remove(photoId)
        var image: CGImage?
        switch outcome {
        case .image(let generated):
            image = generated
            remember(generated, for: photoId)
            generatedCount += 1
        case .unreadable:
            failedIds.insert(photoId)
        case .folderUnreachable:
            // Not the photo's fault: it is retried once the disk is back. The rest of the queue would
            // fail the same way, so the folder is closed until `open` is called again.
            if folder != nil, folderOpening == self.folderOpening {
                Self.logger.notice("Gallery folder went away: showing cached thumbnails only")
                closeFolder()
            }
        }
        for continuation in waiters.removeValue(forKey: photoId) ?? [] {
            continuation.resume(returning: image)
        }
        startWorkers()
        if isIdle {
            if let busySince, generatedCount > 0 {
                let elapsed = ContinuousClock.now - busySince
                Self.logger.info("Thumbnails ready: \(self.generatedCount) in \(elapsed), \(self.failedIds.count) unreadable")
            }
            busySince = nil
            generatedCount = 0
            resumeIdleWaiters()
        }
    }

    private func remember(_ image: CGImage, for photoId: UUID) {
        memory.setObject(image, forKey: photoId as NSUUID, cost: image.bytesPerRow * image.height)
    }

    private func resumeIdleWaiters() {
        for continuation in idleWaiters {
            continuation.resume()
        }
        idleWaiters.removeAll()
    }

    // MARK: - Background work

    // `nonisolated` + `@concurrent`: these run on a background thread, never on the main one.
    // They only receive `Sendable` values (URL, UUID, the cache struct), so there is nothing to share.

    @concurrent
    private nonisolated static func readCached(_ photoId: UUID, from cache: ThumbnailCache) async -> CGImage? {
        cache.image(for: photoId)
    }

    @concurrent
    private nonisolated static func missing(_ photoIds: [UUID], in cache: ThumbnailCache) async -> [UUID] {
        cache.missing(among: photoIds)
    }

    /// Result of one generation. A Swift `enum` can carry a value per case (here the image), like a
    /// TypeScript union `{ kind: "image", image } | { kind: "unreadable" } | …`.
    private enum GenerationOutcome: Sendable {
        case image(CGImage)
        /// The file is there but cannot be read: not retried while this gallery is shown.
        case unreadable
        /// No folder, or it disappeared during the read (disk unplugged, F9).
        case folderUnreachable
    }

    /// Disk cache first (another worker may have made it), then the photo file.
    @concurrent
    private nonisolated static func generate(_ request: ThumbnailRequest, folder: URL?, cache: ThumbnailCache) async -> GenerationOutcome {
        if let cached = cache.image(for: request.photoId) { return .image(cached) }
        guard let folder else { return .folderUnreachable }
        do {
            let url = folder.appending(path: request.relativePath)
            let image = switch MediaKind(relativePath: request.relativePath) {
            case .video: try await VideoReader.frame(url: url, maxPixelSize: ThumbnailGenerator.maxPixelSize)
            case .photo, .unknown: try ThumbnailGenerator.makeThumbnail(from: url)
            }
            try cache.store(image, for: request.photoId)
            return .image(image)
        } catch {
            // A read failing because the disk was just pulled out is not an error of this photo.
            guard FileManager.default.fileExists(atPath: folder.path) else { return .folderUnreachable }
            logger.error("Thumbnail failed for \(request.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
    }

    @concurrent
    private nonisolated static func loadFullSize(_ url: URL) async -> CGImage? {
        try? PreviewLoader.loadFullSize(url: url)
    }

    @concurrent
    private nonisolated static func loadPreview(_ url: URL) async -> CGImage? {
        switch MediaKind(relativePath: url.lastPathComponent) {
        case .video: try? await VideoReader.frame(url: url, maxPixelSize: 2048)
        case .photo, .unknown: try? PreviewLoader.load(url: url)
        }
    }
}
