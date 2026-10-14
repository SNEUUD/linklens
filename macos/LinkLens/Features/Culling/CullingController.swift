import Foundation
import Observation

/// Drives the AI sorting: one gallery at a time, with a queue, visible progress and cancellation.
@MainActor
@Observable
final class CullingController {
    var errorMessage: String?
    private(set) var progress: CullingProgress?
    private(set) var runningGalleryId: UUID?
    private var queue: [Request] = []

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let culler: GalleryCuller
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct Request {
        var galleryId: UUID
        /// False for the automatic sorting at launch: an unplugged disk must not show an alert (F9).
        var reportsErrors: Bool
    }

    init(store: LibraryStore) {
        self.store = store
        culler = GalleryCuller(store: store)
    }

    /// True while the gallery is being sorted or waits for its turn.
    func isBusy(galleryId: UUID) -> Bool {
        runningGalleryId == galleryId || queue.contains { $0.galleryId == galleryId }
    }

    func isQueued(galleryId: UUID) -> Bool {
        queue.contains { $0.galleryId == galleryId }
    }

    /// Sorts (or sorts again) a gallery: after indexing, or from the "Trier à nouveau" button.
    func cull(galleryId: UUID) {
        enqueue(Request(galleryId: galleryId, reportsErrors: true))
    }

    /// At launch: sorts the indexed galleries that were never sorted, silently skipping unreachable folders.
    func cullPendingGalleries() {
        Task {
            let galleryIds = (try? await store.galleriesToCull()) ?? []
            for galleryId in galleryIds {
                enqueue(Request(galleryId: galleryId, reportsErrors: false))
            }
        }
    }

    func cancel(galleryId: UUID) {
        if runningGalleryId == galleryId {
            task?.cancel()
        } else {
            queue.removeAll { $0.galleryId == galleryId }
        }
    }

    private func enqueue(_ request: Request) {
        guard !isBusy(galleryId: request.galleryId) else { return }
        queue.append(request)
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard task == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        runningGalleryId = request.galleryId
        task = Task {
            do {
                _ = try await culler.cullGallery(id: request.galleryId) { [weak self] progress in
                    self?.progress = progress
                }
            } catch is CancellationError {
                // Cancelled by the user: the previous verdicts are kept.
            } catch {
                if request.reportsErrors {
                    errorMessage = error.localizedDescription
                }
            }
            progress = nil
            runningGalleryId = nil
            task = nil
            startNextIfIdle()
        }
    }
}
