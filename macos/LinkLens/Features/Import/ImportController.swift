import AppKit
import Observation

/// Drives "Ajouter un dossier": folder picker, background indexing, progress, cancellation and errors.
///
/// `@Observable` re-renders the views that read a property when it changes, like a small
/// Zustand/MobX store. `@MainActor` keeps it on the main thread, where the interface lives.
@MainActor
@Observable
final class ImportController {
    var selectedGalleryId: UUID?
    var errorMessage: String?
    private(set) var progress: IndexingProgress?
    /// When the running indexing started, for the progress pill.
    private(set) var startedAt: Date?
    private var indexingTask: Task<Void, Never>?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let indexer: FolderIndexer
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    /// Called once a new gallery is fully indexed (starts the AI sorting).
    @ObservationIgnored private let onGalleryIndexed: @MainActor (UUID) -> Void

    var isIndexing: Bool { indexingTask != nil }

    init(store: LibraryStore, onGalleryIndexed: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.store = store
        self.onGalleryIndexed = onGalleryIndexed
        indexer = FolderIndexer(store: store)
        cleanupTask = Task {
            _ = try? await store.deleteUnfinishedGalleries()
        }
    }

    func chooseFolder() {
        guard !isIndexing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Indexer")
        panel.message = String(localized: "Choisissez un dossier de photos. Les fichiers restent à leur place : rien n'est copié, déplacé ni modifié.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        indexFolder(at: folder)
    }

    func cancelIndexing() {
        indexingTask?.cancel()
    }

    private func indexFolder(at folder: URL) {
        // A `Task` starts async work from synchronous code (like calling an async function without awaiting it).
        startedAt = .now
        indexingTask = Task {
            await cleanupTask?.value
            do {
                let result = try await indexer.indexFolder(at: folder) { [weak self] progress in
                    if self?.progress == nil {
                        self?.selectedGalleryId = progress.galleryId
                    }
                    self?.progress = progress
                }
                switch result {
                case .indexed(let galleryId, _):
                    selectedGalleryId = galleryId
                    onGalleryIndexed(galleryId)
                case .alreadyIndexed(let galleryId):
                    selectedGalleryId = galleryId
                }
            } catch is CancellationError {
                if selectedGalleryId == progress?.galleryId {
                    selectedGalleryId = nil
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            progress = nil
            indexingTask = nil
        }
    }
}
