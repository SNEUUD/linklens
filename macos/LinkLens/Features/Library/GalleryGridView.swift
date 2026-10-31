import AppKit
import SwiftUI

/// The photos of a gallery as a grid of thumbnails, with the AI verdict on each one.
/// Arrows move the selection; space, Return or a double-click open the viewer.
/// A burst is a stack showing its best photo: S or its badge open and close it, B chooses its best photo (F4).
/// P / U / X sort the selected photo by hand and go to the next one; A goes back to the AI's proposal.
/// Under a verdict filter, the bursts are unfolded and S shows the whole burst under « Toutes ».
/// ⌘-click, ⇧-click, ⇧ + arrows and ⌘A select several photos (P / U / X then sort them all); Escape
/// selects nothing.
struct GalleryGridView: View {
    let rows: [DisplayedPhoto]
    let loader: ThumbnailLoader
    let browser: GalleryBrowser
    let sorter: ManualSorter
    /// False while the disk is unplugged (F9); when it turns true, cells without a thumbnail ask again.
    var canUseOriginals = true
    /// Width / height of every cell: the dominant orientation of the gallery (`ThumbnailShape`).
    var cellAspectRatio = ThumbnailShape.defaultAspectRatio
    /// Smallest width of a cell, from the size slider and ⌘+ / ⌘−.
    var minimumCellWidth = ThumbnailSize.standard
    /// « Mettre à la corbeille… » of the context menu, with the photos it is about. Nil hides it.
    var onTrash: (([UUID]) -> Void)? = nil
    // `@FocusState` tracks whether this view has the keyboard focus (like `document.activeElement`).
    @FocusState private var isFocused: Bool

    var body: some View {
        // `GeometryReader` gives the available size, needed to know how many photos fit on a row.
        GeometryReader { geometry in
            let columnCount = GridLayout.columnCount(forWidth: geometry.size.width, minimumCellWidth: minimumCellWidth)
            // `ScrollViewReader` gives a `proxy` able to scroll to a view by its id (like `element.scrollIntoView()`).
            ScrollViewReader { proxy in
                ScrollView {
                    // `LazyVGrid` only creates the cells near the visible area, like a virtualised list
                    // (react-window): thousands of photos cost no more than the few on screen.
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: GridLayout.spacing), count: columnCount),
                        spacing: GridLayout.rowSpacing
                    ) {
                        ForEach(rows) { row in
                            let photo = row.photo
                            ThumbnailCell(
                                photo: photo,
                                entry: row.entry,
                                loader: loader,
                                canUseOriginals: canUseOriginals,
                                isSelected: browser.selectedIds.contains(photo.id),
                                cellAspectRatio: cellAspectRatio,
                                onToggleBurst: { number in
                                    browser.selection = photo.id
                                    browser.toggleBurst(number)
                                    isFocused = true
                                },
                                onSort: { command in
                                    let ids = targets(of: photo.id)
                                    if ids == [photo.id] { browser.selection = photo.id }
                                    sorter.apply(command, to: ids)
                                },
                                onBurstCover: { command in
                                    browser.selection = photo.id
                                    sorter.apply(command, to: photo.id)
                                },
                                targets: { targets(of: photo.id) },
                                onSelectWholeBurst: { number in
                                    browser.selectWholeBurst(number)
                                    isFocused = true
                                },
                                onTrash: onTrash.map { trash in { trash(targets(of: photo.id)) } }
                            )
                                .id(photo.id)
                                .onTapGesture(count: 2) { browser.openViewer(on: photo.id) }
                                // `simultaneousGesture`: the single click selects at once, without
                                // waiting to know whether a double-click follows.
                                .simultaneousGesture(TapGesture().onEnded {
                                    // The keys held during the click (a SwiftUI tap does not say).
                                    browser.click(photo.id, modifier: .held(NSEvent.modifierFlags))
                                    isFocused = true
                                })
                        }
                    }
                    .padding(GridLayout.padding)
                }
                .onChange(of: columnCount, initial: true) { browser.columnCount = columnCount }
                // Keeps the selected photo visible (also when coming back from the viewer).
                .onChange(of: browser.selection, initial: true) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
        }
        // `.edit`: takes the keyboard like a text field would; plain `.focusable()` behaves like a
        // button and only gets the focus when "Full Keyboard Access" is turned on in System Settings.
        .focusable(interactions: .edit)
        .focused($isFocused)
        // Tells the menu bar that the photos have the keyboard: ⌘⌫ then deletes the selected photos,
        // not the gallery.
        .focusedValue(\.photosHaveFocus, true)
        .focusEffectDisabled()
        .defaultFocus($isFocused, true)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard let direction = GridLayout.Direction(press.key) else { return .ignored }
            if press.modifiers.contains(.shift) {
                browser.extend(direction)
            } else {
                browser.move(direction)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            browser.clearSelection() ? .handled : .ignored
        }
        // ⌘A is « Tout sélectionner » of the Edit menu: the menu sends the `selectAll:` command to the view
        // that has the keyboard (like a `keydown` handler for one shortcut, but through the menu bar).
        .onCommand(#selector(NSResponder.selectAll(_:))) { browser.selectAll() }
        .onKeyPress(keys: [.space, .return]) { _ in
            browser.openViewer() ? .handled : .ignored
        }
        // S as in Lightroom ("stack"). `.down` only: holding the key does not open and close in a loop.
        .onKeyPress(characters: CharacterSet(charactersIn: "sS"), phases: .down) { _ in
            browser.toggleSelectedBurst() ? .handled : .ignored
        }
        // Manual sorting. `.down` only: holding X does not reject photo after photo.
        .onKeyPress(characters: SortingCommand.keyCharacters, phases: .down) { press in
            guard let command = SortingCommand(press) else { return .ignored }
            return sorter.applyToSelection(command, advance: true) ? .handled : .ignored
        }
        // B as in "best": the selected photo stands for its burst (F4), even after a new sorting.
        .onKeyPress(characters: BurstCoverCommand.keyCharacters, phases: .down) { press in
            guard BurstCoverCommand(press) != nil else { return .ignored }
            return sorter.chooseSelectedBurstCover() ? .handled : .ignored
        }
        .task { isFocused = true }
    }

    /// What a context-menu action applies to: the whole selection when the photo is part of it, else
    /// the photo alone (as in the Finder).
    private func targets(of photoId: UUID) -> [UUID] {
        browser.selectedIds.contains(photoId) ? browser.orderedSelection : [photoId]
    }
}

extension GalleryBrowser.ClickModifier {
    /// ⌘ wins over ⇧, as in the Finder.
    static func held(_ flags: NSEvent.ModifierFlags) -> Self {
        if flags.contains(.command) { return .command }
        if flags.contains(.shift) { return .shift }
        return .none
    }
}

/// One photo of the grid, as in the mockup: rounded thumbnail, verdict badge (top left), star of the
/// burst's best photo (top right), burst count (bottom right), « DSC04311 · rafale de 7 » below.
/// A collapsed burst gets two prints peeking out behind it; the selection gets an accent ring.
private struct ThumbnailCell: View {
    let photo: Photo
    let entry: GalleryEntry
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    let isSelected: Bool
    /// Width / height of the cell, the same for the whole gallery (`ThumbnailShape`).
    let cellAspectRatio: CGFloat
    /// Opens or closes the burst of this photo (receives its number).
    let onToggleBurst: (Int) -> Void
    /// Sorts this photo by hand (context menu, VoiceOver actions).
    let onSort: (SortingCommand) -> Void
    /// Chooses this photo as the best of its burst, or goes back to the AI's choice.
    let onBurstCover: (BurstCoverCommand) -> Void
    /// The photos the context menu acts on (read when it opens): the selection, or this photo alone.
    let targets: () -> [UUID]
    /// « Sélectionner toute la rafale » (receives the burst's number).
    let onSelectWholeBurst: (Int) -> Void
    /// « Mettre à la corbeille… », nil while it is not possible here.
    let onTrash: (() -> Void)?
    // Local state of the cell, like `useState`: the image once loaded.
    @State private var loadedImage: CGImage?

    private var burst: BurstPlacement? { entry.burst }

    var body: some View {
        let image = loadedImage ?? loader.cachedThumbnail(for: photo.id)
        let messages = photo.cullingReasons.map { $0.message() }

        VStack(spacing: 7) {
            thumbnail(image)
                .opacity(entry.isOutsideFilter ? 0.45 : 1)
            Text(verbatim: caption)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
        }
        // The photos of an open burst share a light band, so the burst reads as one block.
        .background {
            if let burst, burst.isExpanded, !burst.isShownAlone {
                RoundedRectangle(cornerRadius: Radius.card + 2)
                    .fill(Color.primary.opacity(0.06))
                    .padding(-6)
            }
        }
        .contentShape(Rectangle())
        // Tooltip on hover: the verdict (and who chose it) and every reason of the AI.
        .help(([photo.verdictDescription, outsideFilterNote].compactMap { $0 } + messages).joined(separator: "\n"))
        .contextMenu {
            let count = targets().count
            if count > 1 {
                // The menu applies to the whole selection: it says so first.
                Text("\(count) photos sélectionnées")
            }
            SortingButtons(showsKeys: true, action: onSort)
            if let burst, count == 1 {
                Divider()
                BurstCoverButtons(burst: burst, showsKeys: true, action: onBurstCover)
                if !burst.isShownAlone {
                    Button("Sélectionner toute la rafale") { onSelectWholeBurst(burst.number) }
                }
            }
            if let onTrash {
                Divider()
                Button(PhotoDeletionText.trashMenuTitle(count: count), systemImage: "trash", role: .destructive, action: onTrash)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel(firstReason: messages.first)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        // VoiceOver lists these actions on the cell (actions menu), since the badges are hidden inside it.
        .accessibilityActions {
            SortingButtons(action: onSort)
            if let burst {
                if !burst.isShownAlone {
                    Button(burst.isExpanded ? "Replier la rafale" : "Voir toute la rafale") { onToggleBurst(burst.number) }
                }
                BurstCoverButtons(burst: burst, action: onBurstCover)
            }
            if let onTrash {
                Button(PhotoDeletionText.trashMenuTitle(count: targets().count), action: onTrash)
            }
        }
        // `.task(id:)` runs async work when the cell appears and cancels it when it scrolls away,
        // like a `useEffect` with `[photo.id]` as dependencies and an abort on cleanup.
        // Runs again when the disk comes back (F9), for the photos that had no cached thumbnail yet.
        .task(id: CellTaskKey(photoId: photo.id, canUseOriginals: canUseOriginals)) {
            if let cached = loader.cachedThumbnail(for: photo.id) {
                loadedImage = cached
            } else {
                loadedImage = await loader.thumbnail(for: photo.thumbnailRequest)
            }
        }
    }

    /// The photo in its cell with the badges over it.
    private func thumbnail(_ image: CGImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.thumbnail)
        // An empty box of the cell's shape; the photo is laid over it, so it can fill the box and be
        // cropped by `clipShape` (CSS `object-fit: cover`) or be shown whole (`contain`).
        return Color.clear
            .aspectRatio(cellAspectRatio, contentMode: .fit)
            .overlay { photoContent(image) }
            .clipShape(shape)
            .shadow(color: .black.opacity(isSelected ? 0.18 : 0.12), radius: isSelected ? 9 : 4, y: isSelected ? 6 : 2)
            .background(alignment: .top) {
                if let burst, !burst.isExpanded {
                    StackSheets()
                }
            }
            .overlay {
                if isSelected {
                    // Drawn outside the photo (CSS `box-shadow: 0 0 0 3px`), so nothing of it is covered.
                    RoundedRectangle(cornerRadius: Radius.thumbnail + 3)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(-3)
                }
            }
            .overlay(alignment: .topLeading) {
                if let verdict = photo.verdict {
                    VerdictDisc(verdict: verdict, isChosenByUser: photo.isVerdictChosenByUser).padding(7)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let burst, burst.showsStar(isBestOfBurst: photo.isBestOfBurst) {
                    BestOfBurstStar(burst: burst).padding(7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let burst, !burst.isShownAlone {
                    BurstBadge(burst: burst) { onToggleBurst(burst.number) }
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if photo.mediaKind == .video {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .photoBadge()
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder private func photoContent(_ image: CGImage?) -> some View {
        if let image {
            let photoRatio = CGFloat(image.width) / CGFloat(max(image.height, 1))
            let fills = ThumbnailShape.fillsCell(photoAspectRatio: photoRatio, cellAspectRatio: cellAspectRatio)
            ZStack {
                Palette.photoBackground.color
                // `decorative`: VoiceOver reads the cell's label instead of the image.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
            }
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: photo.mediaKind == .video ? "video" : "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// « DSC04311 · rafale de 7 »: the file name without its extension, as in the mockup.
    private var caption: String {
        let name = (photo.fileName as NSString).deletingPathExtension
        guard let burst else { return name }
        return String(localized: "\(name) · rafale de \(burst.count)")
    }

    /// Under a verdict filter, for a photo the user just sorted out of it.
    private var outsideFilterNote: String? {
        entry.isOutsideFilter
            ? String(localized: "Ne correspond plus au filtre : elle reste ici jusqu'au prochain changement de filtre.")
            : nil
    }

    /// « DSC04311.ARW, Garder, votre choix, Meilleure de la rafale, Rafale de 7 photos, repliée, <raison> ».
    private func accessibilityLabel(firstReason: String?) -> String {
        let star = burst.flatMap { $0.showsStar(isBestOfBurst: photo.isBestOfBurst) ? $0.starDescription : nil }
        let parts: [String?] = [
            photo.fileName,
            photo.mediaKind == .video ? String(localized: "Vidéo") : nil,
            photo.verdictDescription,
            star,
            burst?.accessibilityDescription,
            entry.isOutsideFilter ? String(localized: "ne correspond plus au filtre") : nil,
            firstReason,
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

private struct CellTaskKey: Hashable {
    var photoId: UUID
    var canUseOriginals: Bool
}

/// Two prints peeking out above the thumbnail of a collapsed burst, like a pile of photos.
private struct StackSheets: View {
    var body: some View {
        ZStack(alignment: .top) {
            sheet(Palette.stackBack.color)
                .padding(.horizontal, 12)
                .offset(y: -8)
            sheet(Palette.stackFront.color)
                .padding(.horizontal, 6)
                .offset(y: -4)
        }
        .accessibilityHidden(true)
    }

    private func sheet(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: Radius.thumbnail)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .frame(height: 40)
    }
}

/// Count pill of a burst, in the bottom corner of its thumbnails. A click opens or closes the burst.
/// Collapsed: stack symbol and photo count. Open: a chevron and the count, in the accent colour.
private struct BurstBadge: View {
    let burst: BurstPlacement
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: burst.isExpanded ? "chevron.up" : "square.on.square")
                Text(verbatim: "\(burst.count)")
            }
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(burst.isExpanded ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Palette.badge.color, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(burst.isExpanded
            ? "Replier la rafale (S)"
            : "Rafale de \(burst.count) photos : voir toutes les photos (S)")
        .accessibilityHidden(true)
    }
}

/// Grid geometry and keyboard moves, kept apart from the view so they can be tested.
enum GridLayout {
    /// Between two photos of a row, and between two rows (room for the caption and the burst prints).
    static let spacing: CGFloat = 18
    static let rowSpacing: CGFloat = 22
    static let padding: CGFloat = 16

    enum Direction {
        case left, right, up, down

        init?(_ key: KeyEquivalent) {
            switch key {
            case .leftArrow: self = .left
            case .rightArrow: self = .right
            case .upArrow: self = .up
            case .downArrow: self = .down
            default: return nil
            }
        }
    }

    /// As many cells of at least `minimumCellWidth` as fit in the width, at least one.
    static func columnCount(forWidth width: CGFloat, minimumCellWidth: CGFloat = ThumbnailSize.standard) -> Int {
        let available = width - 2 * padding + spacing
        return max(1, Int(available / (minimumCellWidth + spacing)))
    }

    /// Index selected after an arrow key, nil if the grid is empty. With no selection, the first photo.
    /// Moves stop at the edges; down from the row above a shorter last row lands on the last photo.
    static func index(moving direction: Direction, from current: Int?, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        switch direction {
        case .left:
            return max(current - 1, 0)
        case .right:
            return min(current + 1, count - 1)
        case .up:
            return current - columns >= 0 ? current - columns : current
        case .down:
            let isOnLastRow = current / columns == (count - 1) / columns
            return isOnLastRow ? current : min(current + columns, count - 1)
        }
    }
}
