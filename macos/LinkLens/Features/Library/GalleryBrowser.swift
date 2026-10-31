import Foundation
import Observation

/// Selection, keyboard navigation and open bursts of the displayed gallery, shared by the grid,
/// the table and the viewer.
///
/// Several photos can be selected (⌘-click, ⇧-click, ⌘A, ⇧ + arrows): `selectedIds`. One of them is the
/// current photo, `selection`: the one the arrows move from, the viewer opens and the inspector shows
/// alone. Only shown photos are ever selected: a collapsed burst is selected through its stack, which
/// stands for its best photo only (« Sélectionner toute la rafale » opens it and selects every photo).
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
    /// Every selected photo, always among the shown ones (`photoIds`).
    private(set) var selectedIds: Set<UUID> = []
    /// The current photo (see the type's comment), nil when nothing is selected.
    private var current: UUID?
    /// Where a ⇧-click or ⇧ + arrow range starts: the last photo clicked or reached without ⇧.
    private var anchor: UUID?
    var isViewerOpen = false
    /// Photos per row in the grid, given by the grid's width.
    var columnCount = 1

    /// The current photo. Setting it selects that photo alone (a click, an arrow, the viewer's ← →).
    // A computed property with a setter: reading or writing `selection` runs these functions, like a
    // getter / setter pair of a TypeScript class.
    var selection: UUID? {
        get { current }
        set { selectOnly(newValue) }
    }

    /// The selected photos in display order.
    var orderedSelection: [UUID] {
        photoIds.filter(selectedIds.contains)
    }

    var isMultipleSelection: Bool { selectedIds.count > 1 }

    var selectedIndex: Int? {
        selection.flatMap { photoIds.firstIndex(of: $0) }
    }

    var selectedEntry: GalleryEntry? {
        selectedIndex.map { entries[$0] }
    }

    /// Called when the photos or their bursts change (indexing, a new sorting).
    func setPhotos(_ photos: [BurstStacks.Input]) {
        guard photos != self.photos else { return }
        let previousIds = photoIds
        let previousCurrent = current
        self.photos = photos
        rebuildEntries()
        // The current photo left the gallery (put in the trash): the next photo shown takes its place,
        // unless other selected photos are still there.
        if let previousCurrent, current == nil, selectedIds.isEmpty, let position = previousIds.firstIndex(of: previousCurrent) {
            let shown = Set(photoIds)
            let next = previousIds[position...].first(where: shown.contains) ?? previousIds[..<position].last(where: shown.contains)
            selectOnly(next)
        }
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

    // MARK: - Several photos

    /// What is held during a click in the grid.
    enum ClickModifier {
        case none
        /// ⌘: adds the photo to the selection, or takes it out.
        case command
        /// ⇧: selects every photo from the last one clicked to this one.
        case shift
    }

    /// A click on a photo of the grid.
    func click(_ photoId: UUID, modifier: ClickModifier) {
        guard photoIds.contains(photoId) else { return }
        switch modifier {
        case .none:
            selectOnly(photoId)
        case .command:
            if selectedIds.contains(photoId) {
                selectedIds.remove(photoId)
                // The current photo goes back to the last selected one shown before it, if any.
                if current == photoId { current = nearestSelected(to: photoId) }
                anchor = current
            } else {
                selectedIds.insert(photoId)
                current = photoId
                anchor = photoId
            }
        case .shift:
            selectRange(to: photoId)
        }
    }

    /// ⌘A: every shown photo (under a filter, only what the filter shows). The current photo stays.
    func selectAll() {
        guard !photoIds.isEmpty else { return }
        selectedIds = Set(photoIds)
        if current == nil { current = photoIds.first }
        if anchor == nil { anchor = current }
    }

    /// Escape: nothing selected any more.
    @discardableResult
    func clearSelection() -> Bool {
        guard current != nil || !selectedIds.isEmpty else { return false }
        selectedIds = []
        current = nil
        anchor = nil
        return true
    }

    /// ⇧ + arrow in the grid: the selection grows (or shrinks) from the anchor to the photo reached.
    func extend(_ direction: GridLayout.Direction) {
        guard let next = GridLayout.index(moving: direction, from: selectedIndex, count: photoIds.count, columns: columnCount) else {
            return
        }
        selectRange(to: photoIds[next])
    }

    /// The table's selection (it handles ⌘-click, ⇧-click, ⌘A and ⇧ + arrows itself). A photo just added
    /// becomes the current one, so the inspector and the viewer follow the last row reached.
    var tableSelection: Set<UUID> {
        get { selectedIds }
        set {
            let shown = newValue.intersection(photoIds)
            let added = photoIds.filter { shown.contains($0) && !selectedIds.contains($0) }
            selectedIds = shown
            if let current, !shown.contains(current) { self.current = nil }
            if added.count == 1 {
                current = added[0]
            } else if !added.isEmpty {
                // A range: its end farthest from the current photo is the row just reached.
                let from = selectedIndex ?? 0
                current = added.max { abs(index(of: $0) - from) < abs(index(of: $1) - from) }
            } else if current == nil {
                current = orderedSelection.last
            }
            if shown.count <= 1 || anchor.map(shown.contains) != true { anchor = current }
        }
    }

    /// « Sélectionner toute la rafale »: opens the burst and selects all its photos.
    func selectWholeBurst(_ number: Int) {
        let members = photos.filter { $0.burstNumber == number }.map(\.id)
        guard !members.isEmpty else { return }
        let previous = current
        if filter != .all {
            expandedBursts.insert(number)
            setFilter(.all)
        } else if !expandedBursts.contains(number) {
            expandedBursts.insert(number)
            rebuildEntries()
        }
        let shown = members.filter(photoIds.contains)
        selectedIds = Set(shown)
        current = previous.flatMap { shown.contains($0) ? $0 : nil } ?? shown.first
        anchor = current
    }

    private func selectOnly(_ photoId: UUID?) {
        current = photoId
        anchor = photoId
        selectedIds = photoId.map { [$0] } ?? []
    }

    private func selectRange(to photoId: UUID) {
        guard let end = photoIds.firstIndex(of: photoId) else { return }
        let start = anchor.flatMap { photoIds.firstIndex(of: $0) } ?? end
        selectedIds = Set(photoIds[min(start, end)...max(start, end)])
        current = photoId
        if anchor == nil { anchor = photoId }
    }

    private func index(of photoId: UUID) -> Int {
        photoIds.firstIndex(of: photoId) ?? 0
    }

    /// The selected photo shown closest before `photoId` (else after it), nil when none is left.
    private func nearestSelected(to photoId: UUID) -> UUID? {
        let position = index(of: photoId)
        let ordered = orderedSelection
        return ordered.last { index(of: $0) < position } ?? ordered.first
    }

    // MARK: - Moving

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
        // Only shown photos stay selected (a burst closed, a filter changed, photos put in the trash).
        let shown = Set(photoIds)
        if !selectedIds.isSubset(of: shown) { selectedIds.formIntersection(shown) }
        if let current, !shown.contains(current) { self.current = orderedSelection.last }
        if let anchor, !shown.contains(anchor) { self.anchor = current }
    }

    /// The first shown photo at or after this one in the gallery's order, else the last shown photo.
    private func nearestShownPhoto(to photoId: UUID) -> UUID? {
        guard let position = photos.firstIndex(where: { $0.id == photoId }) else { return nil }
        return (entries.first { $0.photoIndex >= position } ?? entries.last)?.photoId
    }
}
