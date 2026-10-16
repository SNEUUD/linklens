import Foundation
import Observation
import OSLog

/// Runs `DetailsBackfiller` in the background, one gallery at a time, for the galleries sorted before
/// the inspector existed. Shown in the progress pill, where it can be cancelled.
///
/// Galleries whose originals are out of reach (disk unplugged, F9) are skipped; they are done when the
/// disk comes back. Galleries being sorted are skipped too: the sorting stores the same details.
@MainActor
@Observable
final class DetailsBackfillController {
    private(set) var progress: DetailsProgress?
    private(set) var runningGalleryId: UUID?
    private(set) var startedAt: Date?

    /// False when a gallery's originals cannot be read now, or when it is being sorted. Set by the app.
    @ObservationIgnored var canRead: @MainActor (UUID) -> Bool = { _ in true }
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let backfiller: DetailsBackfiller
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Set by « Annuler »: nothing more is read until the next launch.
    @ObservationIgnored private(set) var isCancelled = false
    private nonisolated static let logger = Logger(subsystem: "fr.chriscrepin.linklens", category: "details")

    init(store: LibraryStore, backfiller: DetailsBackfiller? = nil) {
        self.store = store
        self.backfiller = backfiller ?? DetailsBackfiller(store: store)
    }

    /// At launch and when a disk comes back: queues every gallery with missing details.
    /// The returned task ends once they are queued (the tests wait for it).
    @discardableResult
    func fillPendingGalleries() -> Task<Void, Never> {
        Task {
            guard !isCancelled else { return }
            let galleryIds = (try? await store.galleriesNeedingDetails()) ?? []
            for galleryId in galleryIds where galleryId != runningGalleryId && !queue.contains(galleryId) {
                queue.append(galleryId)
            }
            startNextIfIdle()
        }
    }

    /// « Annuler » in the pill: stops now and forgets the queue. What was saved stays saved.
    func cancel() {
        isCancelled = true
        queue.removeAll()
        task?.cancel()
    }

    /// Waits until nothing runs any more (for the tests).
    func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    private func startNextIfIdle() {
        guard task == nil, !isCancelled else { return }
        // Skips what cannot be read now: it comes back with the next `fillPendingGalleries`.
        while let galleryId = queue.first, !canRead(galleryId) {
            queue.removeFirst()
        }
        guard !queue.isEmpty else { return }
        let galleryId = queue.removeFirst()
        runningGalleryId = galleryId
        startedAt = .now
        task = Task {
            do {
                _ = try await backfiller.fillDetails(galleryId: galleryId) { [weak self] progress in
                    self?.progress = progress
                }
            } catch is CancellationError {
                // « Annuler »: what was saved stays.
            } catch {
                // Folder out of reach: silently left for later (F9), like the automatic sorting.
                Self.logger.info("Details not read: \(error.localizedDescription, privacy: .public)")
            }
            progress = nil
            runningGalleryId = nil
            startedAt = nil
            task = nil
            startNextIfIdle()
        }
    }
}
