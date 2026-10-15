import SwiftUI

/// The photos of a gallery as a grid of thumbnails, with the AI verdict on each one.
/// Arrows move the selection; space, Return or a double-click open the viewer.
/// A burst is a stack showing its best photo: S or its badge open and close it (F4).
struct GalleryGridView: View {
    let rows: [DisplayedPhoto]
    let loader: ThumbnailLoader
    let browser: GalleryBrowser
    /// False while the disk is unplugged (F9); when it turns true, cells without a thumbnail ask again.
    var canUseOriginals = true
    // `@FocusState` tracks whether this view has the keyboard focus (like `document.activeElement`).
    @FocusState private var isFocused: Bool

    var body: some View {
        // `GeometryReader` gives the available size, needed to know how many photos fit on a row.
        GeometryReader { geometry in
            let columnCount = GridLayout.columnCount(forWidth: geometry.size.width)
            // `ScrollViewReader` gives a `proxy` able to scroll to a view by its id (like `element.scrollIntoView()`).
            ScrollViewReader { proxy in
                ScrollView {
                    // `LazyVGrid` only creates the cells near the visible area, like a virtualised list
                    // (react-window): thousands of photos cost no more than the few on screen.
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: GridLayout.spacing), count: columnCount),
                        spacing: GridLayout.spacing
                    ) {
                        ForEach(rows) { row in
                            let photo = row.photo
                            ThumbnailCell(
                                photo: photo,
                                burst: row.entry.burst,
                                loader: loader,
                                canUseOriginals: canUseOriginals,
                                isSelected: photo.id == browser.selection,
                                onToggleBurst: { number in
                                    browser.selection = photo.id
                                    browser.toggleBurst(number)
                                    isFocused = true
                                }
                            )
                                .id(photo.id)
                                .onTapGesture(count: 2) { browser.openViewer(on: photo.id) }
                                // `simultaneousGesture`: the single click selects at once, without
                                // waiting to know whether a double-click follows.
                                .simultaneousGesture(TapGesture().onEnded {
                                    browser.selection = photo.id
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
        .focusEffectDisabled()
        .defaultFocus($isFocused, true)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard let direction = GridLayout.Direction(press.key) else { return .ignored }
            browser.move(direction)
            return .handled
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            browser.openViewer() ? .handled : .ignored
        }
        // S as in Lightroom ("stack"). `.down` only: holding the key does not open and close in a loop.
        .onKeyPress(characters: CharacterSet(charactersIn: "sS"), phases: .down) { _ in
            browser.toggleSelectedBurst() ? .handled : .ignored
        }
        .task { isFocused = true }
    }
}

/// One photo of the grid: thumbnail, verdict, star of the burst, file name, reasons on hover.
/// A collapsed burst is drawn as a stack with its photo count; an open burst gets a tinted background.
private struct ThumbnailCell: View {
    let photo: Photo
    let burst: BurstPlacement?
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    let isSelected: Bool
    /// Opens or closes the burst of this photo (receives its number).
    let onToggleBurst: (Int) -> Void
    // Local state of the cell, like `useState`: the image once loaded.
    @State private var loadedImage: CGImage?

    var body: some View {
        let image = loadedImage ?? loader.cachedThumbnail(for: photo.id)
        let messages = photo.cullingReasons.map { $0.message() }

        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    // `decorative`: VoiceOver reads the cell's label below instead of the image.
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: photo.mediaKind == .video ? "video" : "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            // Same 3:2 box for every photo: portraits get side bands, the grid stays aligned.
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // Two sheets behind a collapsed burst, drawn in the cell's padding: the grid stays aligned.
            .background {
                if let burst, !burst.isExpanded {
                    StackSheets()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let burst {
                    BurstBadge(burst: burst) { onToggleBurst(burst.number) }
                        .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if photo.isBestOfBurst {
                    BestOfBurstStar().padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if photo.mediaKind == .video {
                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let verdict = photo.cullingVerdict {
                    VerdictMark(verdict: verdict).padding(5)
                }
            }

            Text(verbatim: photo.relativePath)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(5)
        .background(cellBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        // Tooltip on hover: the verdict and every reason.
        .help(([photo.cullingVerdict?.label].compactMap { $0 } + messages).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([photo.relativePath, photo.mediaKind == .video ? String(localized: "Vidéo") : nil, photo.cullingVerdict?.label, burst?.accessibilityDescription, messages.first]
                .compactMap { $0 })
                .joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        // VoiceOver lists this action on the cell (actions menu), since the badge is hidden inside it.
        .accessibilityActions {
            if let burst {
                Button(burst.isExpanded ? "Replier la rafale" : "Voir toute la rafale") { onToggleBurst(burst.number) }
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
}

private struct CellTaskKey: Hashable {
    var photoId: UUID
    var canUseOriginals: Bool
}

extension ThumbnailCell {
    /// Selected: accent colour. Photo of an open burst: a neutral tint, so the burst reads as one block.
    private var cellBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if burst?.isExpanded == true { return Color.secondary.opacity(0.14) }
        return .clear
    }
}

/// Two sheets peeking out behind the thumbnail of a collapsed burst, like a pile of prints.
private struct StackSheets: View {
    var body: some View {
        ZStack {
            sheet.offset(x: 5, y: -5).opacity(0.5)
            sheet.offset(x: 2.5, y: -2.5)
        }
    }

    private var sheet: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
    }
}

/// Badge of a burst, in the bottom corner of its thumbnails. A click opens or closes the burst.
/// Collapsed: stack symbol and photo count. Open: the burst number, in the accent colour.
private struct BurstBadge: View {
    let burst: BurstPlacement
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if burst.isExpanded {
                    Label("Rafale \(burst.number)", systemImage: "chevron.up")
                } else {
                    Label {
                        Text(verbatim: "\(burst.count)")
                    } icon: {
                        Image(systemName: "square.stack.fill")
                    }
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(burst.isExpanded ? Color.accentColor : .black.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(burst.isExpanded
            ? "Replier la rafale (S)"
            : "Rafale de \(burst.count) photos : voir toutes les photos (S)")
        .accessibilityHidden(true)
    }
}

extension BurstPlacement {
    /// Read by VoiceOver with the photo's name and verdict.
    var accessibilityDescription: String {
        isExpanded
            ? String(localized: "Rafale \(number), \(count) photos")
            : String(localized: "Rafale de \(count) photos, repliée")
    }
}

/// Grid geometry and keyboard moves, kept apart from the view so they can be tested.
enum GridLayout {
    static let minimumCellWidth: CGFloat = 180
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12

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
    static func columnCount(forWidth width: CGFloat) -> Int {
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
