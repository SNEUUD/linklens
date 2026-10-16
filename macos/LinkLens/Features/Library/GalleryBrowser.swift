import Foundation
import Observation

/// Selection, keyboard navigation and open bursts of the displayed gallery, shared by the grid,
/// the table and the viewer.
///
/// `@Observable` makes SwiftUI redraw the views that read a property when it changes
/// (like a small store, e.g. Zustand). Being a class, every view and key handler holds the same
/// instance and always reads current values: a key handler kept from an older render (SwiftUI
/// does that with `onKeyPress`) still moves from the photo selected now.
@MainActor
@Observable
final class GalleryBrowser {
    /// Every photo of the gallery, in display order, with its burst.
    private(set) var photos: [BurstStacks.Input] = []
    /// Bursts the user opened (F4). Collapsed by default.
    private(set) var expandedBursts: Set<Int> = []
    /// « Toutes », « Garder », « À revoir » or « Rejeter » (see `VerdictFilter` for the rules).
    private(set) var filter = VerdictFilter.all
    /// Photos shown under the current filter, kept on screen after the user sorted them out of it.
    /// Emptied when the filter changes or is chosen again.
    private var retainedIds: Set<UUID> = []
    /// What is shown, in order: single photos, collapsed bursts and photos of open bursts.
    private(set) var entries: [GalleryEntry] = []
    /// Ids of the shown photos (`entries`), in display order.
    private(set) var photoIds: [UUID] = []
    var selection: UUID?
    var isViewerOpen = false
    /// Photos per row in the grid, given by the grid's width.
    var columnCount = 1

    var selectedIndex: Int? {
        selection.flatMap { photoIds.firstIndex(of: $0) }
    }

    var selectedEntry: GalleryEntry? {
        selectedIndex.map { entries[$0] }
    }

    /// Called when the photos or their bursts change (indexing, a new sorting).
    func setPhotos(_ photos: [BurstStacks.Input]) {
        guard photos != self.photos else { return }
        self.photos = photos
        rebuildEntries()
    }

    /// Shows another filter, or the same one again: either way the photos sorted out of it go away.
    /// A selected photo that is not shown any more gives way to the nearest photo shown after it.
    func setFilter(_ filter: VerdictFilter) {
        let previousSelection = selection
        self.filter = filter
        retainedIds = []
        rebuildEntries(keepingShownPhotos: false)
        if let previousSelection, selectedIndex == nil {
            selection = nearestShownPhoto(to: previousSelection)
        }
    }

    /// After a new sorting by the AI: bursts collapsed and the filter applied afresh.
    func gallerySortedAgain() {
        expandedBursts = []
        retainedIds = []
        rebuildEntries(keepingShownPhotos: false)
    }

    /// Opens a collapsed burst or closes an open one.
    func toggleBurst(_ number: Int) {
        if expandedBursts.contains(number) {
            expandedBursts.remove(number)
        } else {
            expandedBursts.insert(number)
        }
        rebuildEntries()
    }

    /// S key: opens or closes the burst of the selected photo. Returns false when it is not in a burst.
    /// Under a verdict filter the bursts are already unfolded: S shows the whole burst under « Toutes »,
    /// open, with the same photo still selected.
    @discardableResult
    func toggleSelectedBurst() -> Bool {
        guard let number = selectedEntry?.burst?.number else { return false }
        if filter != .all {
            expandedBursts.insert(number)
            setFilter(.all)
        } else {
            toggleBurst(number)
        }
        return true
    }

    /// After a new sorting the burst numbers change: every burst starts collapsed again.
    func collapseAllBursts() {
        guard !expandedBursts.isEmpty else { return }
        expandedBursts = []
        rebuildEntries()
    }

    /// Selects a photo, or the stack of its burst when the burst is collapsed (e.g. after ⌘Z).
    func reveal(_ photoId: UUID) {
        if photoIds.contains(photoId) {
            selection = photoId
        } else if filter == .all, let number = photos.first(where: { $0.id == photoId })?.burstNumber,
                  let stack = entries.first(where: { $0.burst?.number == number }) {
            selection = stack.photoId
        }
    }

    /// Arrow key in the grid. With no selection, selects the first photo.
    func move(_ direction: GridLayout.Direction) {
        guard let next = GridLayout.index(moving: direction, from: selectedIndex, count: photoIds.count, columns: columnCount) else {
            return
        }
        selection = photoIds[next]
    }

    /// ← → in the viewer: previous or next photo, stopping at both ends.
    func showNeighbour(offset: Int) {
        guard hasNeighbour(offset: offset), let index = selectedIndex else { return }
        selection = photoIds[index + offset]
    }

    /// False at both ends: the viewer's ‹ › buttons are then disabled.
    func hasNeighbour(offset: Int) -> Bool {
        guard let index = selectedIndex else { return false }
        return photoIds.indices.contains(index + offset)
    }

    /// Opens the viewer on a photo, or on the selected one. Returns false when nothing is selected.
    @discardableResult
    func openViewer(on photoId: UUID? = nil) -> Bool {
        if let photoId { selection = photoId }
        guard selectedIndex != nil else { return false }
        isViewerOpen = true
        return true
    }

    func closeViewer() {
        isViewerOpen = false
    }

    /// - Parameter keepingShownPhotos: true when only the photos changed (a verdict, a burst): what is
    ///   on screen under a verdict filter stays there. False when the filter itself changes.
    private func rebuildEntries(keepingShownPhotos: Bool = true) {
        if keepingShownPhotos, filter != .all {
            retainedIds.formUnion(photoIds)
        }
        entries = BurstStacks.entries(for: photos, expanded: expandedBursts, filter: filter, retaining: retainedIds)
        photoIds = entries.map(\.photoId)
        // A selected photo hidden in a collapsed burst: the burst's stack is selected instead.
        if filter == .all, let selection, selectedIndex == nil,
           let number = photos.first(where: { $0.id == selection })?.burstNumber,
           let stack = entries.first(where: { $0.burst?.number == number }) {
            self.selection = stack.photoId
        }
    }

    /// The first shown photo at or after this one in the gallery's order, else the last shown photo.
    private func nearestShownPhoto(to photoId: UUID) -> UUID? {
        guard let position = photos.firstIndex(where: { $0.id == photoId }) else { return nil }
        return (entries.first { $0.photoIndex >= position } ?? entries.last)?.photoId
    }
}
