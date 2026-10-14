import Foundation
import Observation

/// Selection and keyboard navigation of the displayed gallery, shared by the grid, the table and the viewer.
///
/// `@Observable` makes SwiftUI redraw the views that read a property when it changes
/// (like a small store, e.g. Zustand). Being a class, every view and key handler holds the same
/// instance and always reads current values: a key handler kept from an older render (SwiftUI
/// does that with `onKeyPress`) still moves from the photo selected now.
@MainActor
@Observable
final class GalleryBrowser {
    /// Ids of the photos in display order.
    var photoIds: [UUID] = []
    var selection: UUID?
    var isViewerOpen = false
    /// Photos per row in the grid, given by the grid's width.
    var columnCount = 1

    var selectedIndex: Int? {
        selection.flatMap { photoIds.firstIndex(of: $0) }
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
}
