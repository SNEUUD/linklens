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
    @discardableResult
    func toggleSelectedBurst() -> Bool {
        guard let number = selectedEntry?.burst?.number else { return false }
        toggleBurst(number)
        return true
    }

    /// After a new sorting the burst numbers change: every burst starts collapsed again.
    func collapseAllBursts() {
        guard !expandedBursts.isEmpty else { return }
        expandedBursts = []
        rebuildEntries()
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
        guard let index = selectedIndex, photoIds.indices.contains(index + offset) else { return }
        selection = photoIds[index + offset]
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

    private func rebuildEntries() {
        entries = BurstStacks.entries(for: photos, expanded: expandedBursts)
        photoIds = entries.map(\.photoId)
        // A selected photo hidden in a collapsed burst: the burst's stack is selected instead.
        if let selection, selectedIndex == nil,
           let number = photos.first(where: { $0.id == selection })?.burstNumber,
           let stack = entries.first(where: { $0.burst?.number == number }) {
            self.selection = stack.photoId
        }
    }
}
