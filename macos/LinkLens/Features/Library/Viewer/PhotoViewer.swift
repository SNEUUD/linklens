import SwiftUI

/// The full-window viewer, as in the mockup (Visualiseur.dc.html): the photo large and centred, ‹ › on
/// both sides, the AI's reason in one sentence, the sorting bar and the filmstrip. Its top bar (« ‹ Grille »,
/// name, « Montrer le sujet », inspector) is the window's toolbar, set by `GalleryDetailView`.
///
/// Keys: ← → previous / next photo (as the filter shows them); space or Escape go back; P / U / X sort
/// the photo by hand and show the next one, A goes back to the AI's proposal; B makes it the best of its
/// burst, S opens or closes the burst; Z (or a double-click) shows the photo at 100 % around its subject,
/// Z or Escape come back. ⌥⌘I (« Présentation » menu) shows the inspector.
struct PhotoViewer: View {
    let rows: [DisplayedPhoto]
    /// Index of the photo shown in `rows`.
    let index: Int
    let loader: ThumbnailLoader
    let browser: GalleryBrowser
    let sorter: ManualSorter
    /// Disk unplugged (F9): the largest image in memory or in the cache is shown, with a notice.
    var availability: GalleryAvailability = .available
    /// Width / height of the filmstrip's thumbnails: the gallery's dominant shape (`ThumbnailShape`).
    var cellAspectRatio = ThumbnailShape.defaultAspectRatio

    /// Where « Montrer le sujet » is remembered (shared with the toolbar toggle).
    static let showsSubjectKey = "viewerShowsSubject"
    // On by default, as in the approved mockup: a beginner sees what the AI looked at.
    @AppStorage(PhotoViewer.showsSubjectKey) private var showsSubject = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// The zoom lives in a class, so the key handlers (kept from older renders) read its current state.
    @State private var zoom = ViewerZoom()
    @State private var preview: LoadedImage?
    @State private var thumbnail: LoadedImage?
    @State private var fullSize: LoadedImage?
    @State private var width: CGFloat = 1000
    /// The user's drag while the photo is at 100 %. `@GestureState` goes back to zero by itself when the
    /// drag ends (like a `useState` that resets on pointer up).
    @GestureState private var drag = CGSize.zero
    @FocusState private var isFocused: Bool

    /// An image and the photo it belongs to, so a late image never shows under another photo.
    private struct LoadedImage {
        var photoId: UUID
        var image: CGImage
    }

    var body: some View {
        let row = rows[index]
        let photo = row.photo
        VStack(spacing: 0) {
            photoArea(for: photo)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            VStack(spacing: 10) {
                ViewerReasonPill(line: ViewerReasonLine(photo: photo)) {
                    sorter.apply(.followAI, to: [photo.id])
                }
                ViewerSortingBar(
                    photo: photo,
                    burst: row.entry.burst,
                    onSort: { command in sorter.apply(command, to: [photo.id]) },
                    onBurstCover: { sorter.apply(.choose, to: photo.id) },
                    onToggleBurst: { browser.toggleSelectedBurst() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            ViewerFilmstrip(
                strip: filmstrip,
                photosById: photosById,
                selection: photo.id,
                loader: loader,
                canUseOriginals: availability.canUseOriginals,
                itemSize: itemSize,
                onSelect: { photoId in
                    browser.selection = photoId
                    isFocused = true
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.viewer.color.ignoresSafeArea())
        // `onGeometryChange` reports a size whenever it changes, like a `ResizeObserver`.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // « Réduire les animations » (System Settings › Accessibility): no fade, no animated zoom.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: photo.id)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: zoom.isZoomed)
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .defaultFocus($isFocused, true)
        .task { isFocused = true }
        // The handlers only call `browser`, `sorter` and `zoom`: objects that always know the photo shown now.
        .onKeyPress(.leftArrow) {
            browser.showNeighbour(offset: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            browser.showNeighbour(offset: 1)
            return .handled
        }
        .onKeyPress(.space) {
            browser.closeViewer()
            return .handled
        }
        // Escape first leaves the 100 % zoom, then the viewer.
        .onKeyPress(.escape) {
            if zoom.isZoomed {
                zoom.toggle()
            } else {
                browser.closeViewer()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ"), phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
            return zoom.toggle() ? .handled : .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS"), phases: .down) { _ in
            browser.toggleSelectedBurst() ? .handled : .ignored
        }
        .onKeyPress(characters: SortingCommand.keyCharacters, phases: .down) { press in
            guard let command = SortingCommand(press) else { return .ignored }
            return sorter.applyToSelection(command, advance: true) ? .handled : .ignored
        }
        // B as in "best": the selected photo stands for its burst (F4), even after a new sorting.
        .onKeyPress(characters: BurstCoverCommand.keyCharacters, phases: .down) { press in
            guard BurstCoverCommand(press) != nil else { return .ignored }
            return sorter.chooseSelectedBurstCover() ? .handled : .ignored
        }
        // Zoom needs the original file: not for a video, nor while the disk is unplugged (F9).
        .onChange(of: canZoom(photo), initial: true) { _, canZoom in
            zoom.isAvailable = canZoom
            if !canZoom, zoom.isZoomed { zoom.toggle() }
        }
        // Another photo: the zoom stays on (to compare the photos of a burst), framed on its subject.
        .onChange(of: photo.id) { zoom.pan = .zero }
        // Again when the disk comes back (F9): the full preview replaces the cached thumbnail.
        .task(id: LoadKey(photoId: photo.id, canUseOriginals: availability.canUseOriginals)) { await load(photo) }
        .task(id: FullSizeKey(photoId: photo.id, isZoomed: zoom.isZoomed, canUseOriginals: availability.canUseOriginals)) {
            guard zoom.isZoomed, let image = await loader.fullImage(for: photo.thumbnailRequest) else { return }
            fullSize = LoadedImage(photoId: photo.id, image: image)
        }
    }

    private struct LoadKey: Hashable {
        var photoId: UUID
        var canUseOriginals: Bool
    }

    private struct FullSizeKey: Hashable {
        var photoId: UUID
        var isZoomed: Bool
        var canUseOriginals: Bool
    }

    private func canZoom(_ photo: Photo) -> Bool {
        availability.canUseOriginals && photo.mediaKind != .video
    }

    // MARK: - Filmstrip

    private var photosById: [UUID: Photo] {
        Dictionary(rows.map { ($0.id, $0.photo) }, uniquingKeysWith: { first, _ in first })
    }

    private var itemSize: CGSize {
        CGSize(width: (ViewerFilmstrip.itemHeight * cellAspectRatio).rounded(), height: ViewerFilmstrip.itemHeight)
    }

    private var filmstrip: Filmstrip {
        let dimmedWidth = (ViewerFilmstrip.dimmedHeight * cellAspectRatio).rounded()
        let fitting = Filmstrip.itemsFitting(width: width - 32, itemWidth: itemSize.width, dimmedWidth: dimmedWidth)
        return Filmstrip.make(entries: rows.map(\.entry), selection: rows[index].id, maxItems: fitting)
    }

    // MARK: - Photo

    /// The best image there is now: the full preview, else the grid thumbnail (or, disk unplugged, the
    /// largest image kept in memory or in the cache).
    private func shownImage(for photo: Photo) -> (image: CGImage?, isReduced: Bool) {
        let loadedPreview = preview?.photoId == photo.id ? preview?.image : nil
        let image = loadedPreview
            ?? (thumbnail?.photoId == photo.id ? thumbnail?.image : nil)
            ?? loader.cachedThumbnail(for: photo.id)
        return (image, loadedPreview == nil)
    }

    private func photoArea(for photo: Photo) -> some View {
        let shown = shownImage(for: photo)
        return GeometryReader { geometry in
            let area = geometry.size
            let fitted = fittedSize(of: shown.image, photo: photo, in: area)
            ZStack {
                if zoom.isZoomed, let image = shown.image {
                    zoomedPhoto(photo, fallback: image, area: area)
                } else if let image = shown.image {
                    photoImage(image, photo: photo, size: fitted)
                } else if !availability.canUseOriginals {
                    // No thumbnail was made while the disk was there: nothing to show, but no endless spinner either.
                    ContentUnavailableView("Pas de miniature en cache", systemImage: "photo")
                } else {
                    ProgressView()
                }
            }
            .frame(width: area.width, height: area.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { zoom.toggle() }
            .overlay(alignment: .top) {
                if zoom.isZoomed {
                    zoomBadge(isLoading: fullSize?.photoId != photo.id)
                }
            }
            .overlay(alignment: .bottom) {
                if let message = availability.message, shown.isReduced {
                    Label("Aperçu réduit : \(message)", systemImage: availability.systemImage)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassBackground()
                        .padding(12)
                        .help("Les fichiers originaux ne sont pas accessibles : LinkLens montre la plus grande image gardée en cache.")
                }
            }
            .overlay { arrows(area: area, photoWidth: zoom.isZoomed ? area.width : fitted.width) }
        }
    }

    /// The photo whole, as large as the area allows (never enlarged past its aspect ratio).
    private func fittedSize(of image: CGImage?, photo: Photo, in area: CGSize) -> CGSize {
        var aspect: CGFloat = 1.5
        if let image, image.height > 0 {
            aspect = CGFloat(image.width) / CGFloat(image.height)
        } else if photo.pixelHeight > 0 {
            aspect = CGFloat(photo.pixelWidth) / CGFloat(photo.pixelHeight)
        }
        guard area.width > 0, area.height > 0 else { return .zero }
        let width = min(area.width, area.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func photoImage(_ image: CGImage, photo: Photo, size: CGSize) -> some View {
        let subject = showsSubject ? photo.subjectBox : nil
        let line = ViewerReasonLine(photo: photo)
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            // Waiting for its disk to go to the trash: dimmed, with the bin in the corner.
            .opacity(photo.isPendingTrash ? PendingTrashStyle.opacity : 1)
            .overlay(alignment: .topLeading) {
                if photo.isPendingTrash {
                    PendingTrashBadge(size: 30).padding(12)
                }
            }
            .overlay {
                if let subject {
                    // Placed in the coordinates of the drawn photo, as in the inspector.
                    SubjectFrame()
                        .frame(width: subject.width * size.width, height: subject.height * size.height)
                        .position(x: subject.midX * size.width, y: subject.midY * size.height)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 25, y: 18)
            .id(photo.id)
            .transition(.opacity)
            .help(canZoom(photo) ? "Double-cliquez ou appuyez sur Z pour voir la photo à 100 %" : "")
            // VoiceOver: « DSC04311.ARW, Garder », then the reason; the sorting keys as actions.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(photo.fileName), \(photo.verdictDescription ?? String(localized: "pas encore triée"))"
                + (photo.isPendingTrash ? ", " + PendingTrashText.accessibilityLabel : "")))
            .accessibilityValue(Text(verbatim: accessibilityValue(line: line, subject: subject)))
            .accessibilityAddTraits(.isImage)
            .accessibilityActions {
                SortingButtons { command in sorter.apply(command, to: [photo.id]) }
            }
    }

    private func accessibilityValue(line: ViewerReasonLine, subject: CGRect?) -> String {
        guard let subject else { return line.text }
        return line.text + " " + InspectorSubject.accessibilityDescription(of: subject)
    }

    /// The photo at 100 %: the full-resolution image once read (about a second for a RAW), the preview
    /// enlarged meanwhile. Framed on the subject; the user can drag it around.
    private func zoomedPhoto(_ photo: Photo, fallback: CGImage, area: CGSize) -> some View {
        let full = fullSize?.photoId == photo.id ? fullSize?.image : nil
        let image = full ?? fallback
        // The size of the original, so nothing jumps when the full image replaces the preview.
        let pixels = full.map { ($0.width, $0.height) }
            ?? (photo.pixelWidth > 0 ? (photo.pixelWidth, photo.pixelHeight) : (fallback.width, fallback.height))
        let size = ZoomFraming.actualSize(pixelWidth: pixels.0, pixelHeight: pixels.1, displayScale: displayScale)
        let focus = ZoomFraming.focus(subject: photo.subjectBox)
        let pan = CGSize(width: zoom.pan.width + drag.width, height: zoom.pan.height + drag.height)
        let offset = ZoomFraming.offset(photoSize: size, viewport: area, focus: focus, pan: pan)
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .offset(offset)
            .frame(width: area.width, height: area.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        let dragged = CGSize(width: zoom.pan.width + value.translation.width, height: zoom.pan.height + value.translation.height)
                        zoom.pan = ZoomFraming.settledPan(photoSize: size, viewport: area, focus: focus, pan: dragged)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(photo.fileName) à 100 %"))
            .accessibilityAddTraits(.isImage)
            .accessibilityHint(Text("Z ou Échap pour revenir"))
    }

    private func zoomBadge(isLoading: Bool) -> some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Lecture de la pleine définition…")
            } else {
                Text(verbatim: "100 %").fontWeight(.semibold)
            }
            Text("· Z ou Échap pour revenir").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassBackground()
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    /// ‹ › in round glass buttons, a little away from the photo's sides (at the window's edges while zoomed).
    private func arrows(area: CGSize, photoWidth: CGFloat) -> some View {
        let distance = min(max(30, (area.width - photoWidth) / 2 - 64), area.width / 2 - 30)
        return ZStack {
            ViewerArrowButton(isNext: false, isEnabled: browser.hasNeighbour(offset: -1)) {
                browser.showNeighbour(offset: -1)
            }
            .position(x: distance, y: area.height / 2)
            ViewerArrowButton(isNext: true, isEnabled: browser.hasNeighbour(offset: 1)) {
                browser.showNeighbour(offset: 1)
            }
            .position(x: area.width - distance, y: area.height / 2)
        }
    }

    // MARK: - Loading

    private func load(_ photo: Photo) async {
        let request = photo.thumbnailRequest
        if loader.cachedThumbnail(for: photo.id) == nil, let image = await loader.thumbnail(for: request) {
            thumbnail = LoadedImage(photoId: photo.id, image: image)
        }
        if let image = await loader.preview(for: request) {
            preview = LoadedImage(photoId: photo.id, image: image)
        }
        // Reads the neighbours ahead, so the next arrow key shows the full image at once.
        for neighbour in [index + 1, index - 1] where rows.indices.contains(neighbour) {
            guard !Task.isCancelled else { return }
            _ = await loader.preview(for: rows[neighbour].photo.thumbnailRequest)
        }
    }
}

/// Whether the viewer shows the photo at 100 %, and how far the user dragged it.
@MainActor
@Observable
final class ViewerZoom {
    private(set) var isZoomed = false
    /// Added to the framing on the subject (`ZoomFraming`); back to zero for each new zoom or photo.
    var pan = CGSize.zero
    /// False for a video or while the disk is unplugged: Z then does nothing.
    var isAvailable = true

    /// Z, a double-click or Escape. Returns false when the zoom cannot start.
    @discardableResult
    func toggle() -> Bool {
        guard isZoomed || isAvailable else { return false }
        isZoomed.toggle()
        pan = .zero
        return true
    }
}

extension ViewerReasonLine {
    init(photo: Photo) {
        self.init(
            aiVerdict: photo.cullingVerdict,
            userVerdict: photo.isVerdictChosenByUser ? (photo.userVerdict ?? .unknown) : nil,
            reasons: photo.cullingReasons,
            hasSubject: photo.subjectBox != nil,
            isVideo: photo.mediaKind == .video
        )
    }
}
