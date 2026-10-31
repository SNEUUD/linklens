import SwiftUI

/// The review of the « À revoir » photos, over the whole window like the viewer. One stop at a time:
/// a burst (its best photo ★ and the photo compared with it, large, side by side, the whole burst below)
/// or a single photo; at the end, the summary.
///
/// Keys: Return keeps the ★ and rejects the others (burst), then shows the next stop; Space goes to the
/// next stop without changing anything; ← → move through the burst, then to the stop before or after;
/// P / U / X sort the photo shown and move on, A gives it back to the AI; B makes it the best of its burst;
/// Z shows both photos at 100 % at the same place; Escape leaves (the position is kept). ⌘Z undoes.
struct ReviewModeView: View {
    let session: ReviewSession
    let photosById: [UUID: Photo]
    let loader: ThumbnailLoader
    let sorter: ManualSorter
    var availability: GalleryAvailability = .available
    /// Escape, « Terminer », « Revenir aux photos ».
    let onClose: () -> Void
    /// « Revoir les N restantes » at the end: a new review of the photos still « À revoir ».
    let onReviewRemaining: () -> Void
    /// « Mettre les N photos rejetées à la corbeille… » at the end, N = every photo of the gallery shown
    /// as « Rejeter » (not only those of the review: the same set as the « Galerie » menu and the
    /// « Rejeter » filter). Nil hides the button (no rejected photo, disk unplugged…).
    var trashRejected: TrashRejectedAction? = nil

    /// Shared by both photos of a burst: Z zooms both, a drag moves both.
    @State private var zoom = ViewerZoom()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let stop = session.currentStop {
                header(for: stop)
                if stop.isBurst {
                    burstStop(stop)
                } else {
                    singleStop(stop)
                }
            } else {
                ReviewSummaryView(
                    summary: session.summary,
                    onClose: onClose,
                    onReviewRemaining: onReviewRemaining,
                    trashRejected: trashRejected
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.viewer.color.ignoresSafeArea())
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .defaultFocus($isFocused, true)
        .task { isFocused = true }
        // ⌘Z / ⇧⌘Z: the review goes back to the stop of the photo that changed. `[weak session]` keeps the
        // sorter from holding the review alive (like a `WeakRef`).
        .onAppear {
            sorter.onRestore = { [weak session] photoId in session?.reveal(photoId) }
        }
        .onDisappear { sorter.onRestore = nil }
        // The handlers only call `session`, `sorter` and `zoom`: objects that always know the stop shown
        // now (SwiftUI may keep a handler from an older render).
        .onKeyPress(.return) {
            if session.isFinished {
                onClose()
                return .handled
            }
            return session.keepBestRejectOthers(using: sorter) ? .handled : .ignored
        }
        .onKeyPress(.space) {
            guard !session.isFinished else { return .ignored }
            session.skip()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            session.moveForward()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            session.moveBack()
            return .handled
        }
        // Escape first leaves the 100 % zoom, then the review.
        .onKeyPress(.escape) {
            if zoom.isZoomed {
                zoom.toggle()
            } else {
                onClose()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ"), phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]), !session.isFinished else { return .ignored }
            return zoom.toggle() ? .handled : .ignored
        }
        .onKeyPress(characters: SortingCommand.keyCharacters, phases: .down) { press in
            guard let command = SortingCommand(press) else { return .ignored }
            return session.sort(command, using: sorter) ? .handled : .ignored
        }
        .onKeyPress(characters: BurstCoverCommand.keyCharacters, phases: .down) { press in
            guard BurstCoverCommand(press) != nil else { return .ignored }
            return session.chooseBest(using: sorter) ? .handled : .ignored
        }
        // Zoom needs the original files: not for a video, nor while the disk is unplugged (F9).
        .onChange(of: canZoom, initial: true) { _, canZoom in
            zoom.isAvailable = canZoom
            if !canZoom, zoom.isZoomed { zoom.toggle() }
        }
        // Another stop: the 100 % framing starts again on its subject. Within a burst it stays, so each
        // photo is compared at the same place.
        .onChange(of: session.position) { zoom.pan = .zero }
        .onChange(of: AnnouncementKey(position: session.position, focus: session.focusedPhotoId)) { old, new in
            announce(stopChanged: old.position != new.position)
        }
    }

    private struct AnnouncementKey: Equatable {
        var position: Int
        var focus: UUID?
    }

    private var canZoom: Bool {
        guard availability.canUseOriginals, let id = session.focusedPhotoId else { return false }
        return photosById[id]?.mediaKind != .video
    }

    // MARK: - Header

    private func header(for stop: ReviewStop) -> some View {
        let shownCount = session.shownIds(of: stop).count
        return ReviewHeader(
            kind: ReviewText.kind(of: stop, shownCount: shownCount),
            counter: ReviewText.counter(position: session.position, total: session.stops.count),
            remaining: ReviewText.remaining(session.remainingCount),
            progress: Double(session.position) / Double(max(session.stops.count, 1)),
            notice: availability.canUseOriginals ? nil : availability.message.map {
                String(localized: "Aperçu réduit, zoom 100 % indisponible : \($0)")
            }
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: - Burst

    private func burstStop(_ stop: ReviewStop) -> some View {
        let ids = session.shownIds(of: stop)
        let bestId = session.bestId(of: stop)
        let focusedId = session.focusedPhotoId
        let compared = focusedId.flatMap { $0 == bestId ? nil : photosById[$0] }
        let best = bestId.flatMap { photosById[$0] }
        let zoomFocus = ZoomFraming.focus(subject: best?.subjectBox)
        return VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                if let best {
                    pane(best, role: .best(chosenByUser: session.isBestChosenByUser(in: stop)), zoomFocus: zoomFocus)
                }
                if let compared {
                    pane(compared, role: .compared, zoomFocus: zoomFocus)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            ReviewBurstStrip(
                ids: ids, photosById: photosById, bestId: bestId, focusedId: focusedId,
                reviewIds: Set(stop.reviewIds), loader: loader, canUseOriginals: availability.canUseOriginals,
                onSelect: { id in
                    session.focus(id)
                    isFocused = true
                }
            )
            .padding(.horizontal, 20)
            burstActions(focused: focusedId.flatMap { photosById[$0] }, isBest: focusedId == bestId)
            hints(String(localized: "← → parcourir la rafale · Z : les deux photos à 100 % · Échap : quitter, la position est gardée"))
                .padding(.bottom, 12)
        }
        // VoiceOver: the decision of the whole burst is an action of the stop, as the Return key.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: ReviewText.kind(of: stop, shownCount: ids.count)))
        .accessibilityAction(named: Text("Garder la meilleure, rejeter les autres")) {
            session.keepBestRejectOthers(using: sorter)
        }
        .accessibilityAction(named: Text("Rafale suivante, sans rien changer")) { session.skip() }
    }

    /// « Garder la ★, rejeter les autres ↩ », « Rafale suivante ␣ », then the sorting of the photo shown.
    private func burstActions(focused: Photo?, isBest: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                session.keepBestRejectOthers(using: sorter)
                isFocused = true
            } label: {
                HStack(spacing: 8) {
                    Text("Garder la \(Image(systemName: "star.fill")), rejeter les autres")
                    ProminentKeyCap("↩")
                }
            }
            .buttonStyle(.capsule(.prominent))
            .help("La meilleure photo devient « Garder », les autres « Rejeter » (sauf celles que vous avez gardées avec P). Rien n'est supprimé. (Retour)")
            .accessibilityLabel(Text("Garder la meilleure, rejeter les autres, touche Retour"))
            Button {
                session.skip()
                isFocused = true
            } label: {
                HStack(spacing: 8) {
                    Text("Rafale suivante")
                    KeyCap(String(localized: "Espace"))
                }
            }
            .buttonStyle(.capsule())
            .help("Passer à la suite sans rien changer (Espace)")
            .accessibilityLabel(Text("Rafale suivante sans rien changer, touche Espace"))
            if let focused {
                ReviewSortingBar(photo: focused, isBest: isBest, showsBest: true) { command in
                    session.sort(command, using: sorter)
                    isFocused = true
                } onBest: {
                    session.chooseBest(using: sorter)
                    isFocused = true
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Single photo

    private func singleStop(_ stop: ReviewStop) -> some View {
        let photo = session.focusedPhotoId.flatMap { photosById[$0] }
        return VStack(spacing: 14) {
            if let photo {
                pane(photo, role: .single, zoomFocus: ZoomFraming.focus(subject: photo.subjectBox))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                HStack(spacing: 12) {
                    ReviewSortingBar(photo: photo, isBest: false, showsBest: false) { command in
                        session.sort(command, using: sorter)
                        isFocused = true
                    } onBest: {}
                    Button {
                        session.skip()
                        isFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Text("Passer")
                            KeyCap(String(localized: "Espace"))
                        }
                    }
                    .buttonStyle(.capsule())
                    .help("Photo suivante sans rien changer (→ ou Espace)")
                    .accessibilityLabel(Text("Passer sans rien changer, touche Espace"))
                }
            } else {
                Spacer()
            }
            hints(String(localized: "P, U, X : trier puis passer à la suite · → ou Espace : passer · ← : revenir · Échap : quitter"))
                .padding(.bottom, 12)
        }
    }

    // MARK: - Parts

    private func pane(_ photo: Photo, role: ReviewPhotoPane.Role, zoomFocus: CGPoint) -> some View {
        ReviewPhotoPane(
            photo: photo, role: role, loader: loader, canUseOriginals: availability.canUseOriginals,
            zoom: zoom, zoomFocus: zoomFocus,
            onSort: { command in sorter.apply(command, to: [photo.id]) },
            onKeepBest: role.isBurst ? { session.keepBestRejectOthers(using: sorter) } : nil
        )
    }

    private func hints(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 20)
    }

    /// VoiceOver: the stop (« Rafale de 7 photos, 4 sur 9, reste 12 photos à revoir ») and the photo shown,
    /// or only the photo when moving inside a burst, or the summary.
    private func announce(stopChanged: Bool) {
        var parts: [String] = []
        if let stop = session.currentStop {
            if stopChanged {
                parts.append(ReviewText.stopAnnouncement(
                    stop, shownCount: session.shownIds(of: stop).count, position: session.position,
                    total: session.stops.count, remainingCount: session.remainingCount
                ))
            }
            if let photo = session.focusedPhotoId.flatMap({ photosById[$0] }) {
                parts.append(ReviewPhotoPane.spokenLabel(of: photo, isBest: photo.id == session.bestId(of: stop)))
                parts.append(ViewerReasonLine(photo: photo).text)
            }
        } else {
            parts.append(ReviewText.summaryAnnouncement(session.summary))
        }
        AccessibilityNotification.Announcement(parts.joined(separator: ". ")).post()
    }
}

// MARK: - Header

/// « Rafale de 7 photos · 4 sur 9 » on the left, « reste 12 photos à revoir » on the right, a thin
/// progress bar below.
private struct ReviewHeader: View {
    let kind: String
    let counter: String
    let remaining: String
    let progress: Double
    /// Disk unplugged (F9): reduced previews and no 100 % zoom.
    let notice: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: kind).fontWeight(.semibold)
                Text(verbatim: "·").foregroundStyle(.secondary)
                Text(verbatim: counter).monospacedDigit()
                Spacer(minLength: 12)
                if let notice {
                    Label(notice, systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(Palette.review.color)
                        .lineLimit(1)
                        .help("Les fichiers originaux ne sont pas accessibles : LinkLens montre les miniatures gardées en cache.")
                }
                Text(verbatim: remaining)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Photo

/// One photo of the review, as large as the space allows, with its badge, its name and the AI's reason
/// (the viewer's pill). At 100 % (Z) it is framed on `zoomFocus`, the same point for both photos of a burst.
struct ReviewPhotoPane: View {
    enum Role: Equatable {
        /// The burst's best photo (★), chosen by the AI or by the user (B).
        case best(chosenByUser: Bool)
        /// The photo of the burst compared with the best one.
        case compared
        case single

        var isBurst: Bool { self != .single }
    }

    let photo: Photo
    let role: Role
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    let zoom: ViewerZoom
    let zoomFocus: CGPoint
    /// VoiceOver actions on the photo.
    let onSort: (SortingCommand) -> Void
    let onKeepBest: (() -> Void)?

    @Environment(\.displayScale) private var displayScale
    @State private var image: LoadedImage?
    @State private var fullSize: LoadedImage?
    /// Where `zoom.pan` was when the drag began: both photos follow the drag.
    @State private var dragStart: CGSize?

    private struct LoadedImage {
        var photoId: UUID
        var image: CGImage
    }

    var body: some View {
        VStack(spacing: 10) {
            title
            GeometryReader { geometry in
                photoArea(in: geometry.size)
            }
            ViewerReasonPill(line: ViewerReasonLine(photo: photo)) { onSort(.followAI) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: LoadKey(photoId: photo.id, canUseOriginals: canUseOriginals)) { await load() }
        .task(id: FullSizeKey(photoId: photo.id, isZoomed: zoom.isZoomed, canUseOriginals: canUseOriginals)) {
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

    /// « ★ Meilleure de la rafale · DSC04311 » or « ? DSC04312 · À revoir ».
    private var title: some View {
        HStack(spacing: 8) {
            switch role {
            case .best(let chosenByUser):
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.gold.color)
                    .photoBadge(ringColor: chosenByUser ? Palette.gold.color : nil)
                Text(chosenByUser ? "Meilleure de la rafale, votre choix" : "Meilleure de la rafale")
                    .fontWeight(.semibold)
            case .compared, .single:
                if let verdict = photo.verdict {
                    VerdictDisc(verdict: verdict, isChosenByUser: photo.isVerdictChosenByUser)
                }
                Text(verbatim: photo.verdictDescription ?? String(localized: "pas encore triée"))
                    .fontWeight(.semibold)
            }
            Text(verbatim: (photo.fileName as NSString).deletingPathExtension)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func photoArea(in area: CGSize) -> some View {
        let shown = image?.photoId == photo.id ? image?.image : loader.cachedThumbnail(for: photo.id)
        ZStack {
            if zoom.isZoomed, let shown {
                zoomed(fallback: shown, area: area)
            } else if let shown {
                let size = fittedSize(of: shown, in: area)
                Image(decorative: shown, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.small)
                            .strokeBorder(role == .compared ? Color.accentColor : .clear, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 14)
            } else if !canUseOriginals {
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
        // VoiceOver: « DSC04312.ARW, À revoir », then the reason; sorting and the burst decision as actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spokenLabel(of: photo, isBest: { if case .best = role { true } else { false } }())))
        .accessibilityValue(Text(verbatim: ViewerReasonLine(photo: photo).text))
        .accessibilityAddTraits(.isImage)
        .accessibilityActions {
            if let onKeepBest {
                Button("Garder la meilleure, rejeter les autres", action: onKeepBest)
            }
            SortingButtons(action: onSort)
        }
    }

    /// « DSC04311.ARW, meilleure de la rafale, Garder ».
    static func spokenLabel(of photo: Photo, isBest: Bool) -> String {
        var parts = [photo.fileName]
        if isBest { parts.append(String(localized: "meilleure de la rafale")) }
        parts.append(photo.verdictDescription ?? String(localized: "pas encore triée"))
        return parts.joined(separator: ", ")
    }

    private func fittedSize(of image: CGImage, in area: CGSize) -> CGSize {
        guard image.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let width = min(area.width, area.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// At 100 %: the full-resolution image once read, the preview enlarged meanwhile.
    private func zoomed(fallback: CGImage, area: CGSize) -> some View {
        let full = fullSize?.photoId == photo.id ? fullSize?.image : nil
        let pixels = full.map { ($0.width, $0.height) }
            ?? (photo.pixelWidth > 0 ? (photo.pixelWidth, photo.pixelHeight) : (fallback.width, fallback.height))
        let size = ZoomFraming.actualSize(pixelWidth: pixels.0, pixelHeight: pixels.1, displayScale: displayScale)
        let offset = ZoomFraming.offset(photoSize: size, viewport: area, focus: zoomFocus, pan: zoom.pan)
        return Image(decorative: full ?? fallback, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .offset(offset)
            .frame(width: area.width, height: area.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStart ?? zoom.pan
                        dragStart = start
                        zoom.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                    }
                    .onEnded { _ in
                        zoom.pan = ZoomFraming.settledPan(photoSize: size, viewport: area, focus: zoomFocus, pan: zoom.pan)
                        dragStart = nil
                    }
            )
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
        .padding(10)
        .accessibilityElement(children: .combine)
    }

    /// The cached thumbnail first (at once, also with the disk unplugged), then the large preview.
    private func load() async {
        let request = photo.thumbnailRequest
        if loader.cachedThumbnail(for: photo.id) == nil, let thumbnail = await loader.thumbnail(for: request) {
            image = LoadedImage(photoId: photo.id, image: thumbnail)
        }
        if let preview = await loader.preview(for: request) {
            image = LoadedImage(photoId: photo.id, image: preview)
        }
    }
}

// MARK: - Burst strip

/// Every photo of the burst, small, in order: its verdict badge, the star on the best one, and its reason in
/// a few words. A click compares it with the best one.
private struct ReviewBurstStrip: View {
    let ids: [UUID]
    let photosById: [UUID: Photo]
    let bestId: UUID?
    let focusedId: UUID?
    /// The photos that were « À revoir » when the review started (their reason is in bold).
    let reviewIds: Set<UUID>
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    let onSelect: (UUID) -> Void

    private static let itemSize = CGSize(width: 104, height: 70)

    var body: some View {
        // `ScrollViewReader` gives a `proxy` that scrolls to an element by its id (like `scrollIntoView`).
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        if let photo = photosById[id] {
                            item(photo).id(id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: focusedId, initial: true) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxWidth: CGFloat(ids.count) * (Self.itemSize.width + 10) + 24)
        .glassBackground(in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Photos de la rafale"))
    }

    private func item(_ photo: Photo) -> some View {
        let isFocused = photo.id == focusedId
        let isBest = photo.id == bestId
        return Button {
            onSelect(photo.id)
        } label: {
            VStack(spacing: 5) {
                FilmstripThumbnail(photo: photo, loader: loader, canUseOriginals: canUseOriginals, size: Self.itemSize)
                    .overlay {
                        if isFocused || isBest {
                            RoundedRectangle(cornerRadius: Radius.small + 1.25)
                                .stroke(isBest ? Palette.gold.color : Color.accentColor, lineWidth: 2.5)
                                .padding(-1.25)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let verdict = photo.verdict {
                            VerdictDisc(verdict: verdict, isChosenByUser: photo.isVerdictChosenByUser)
                                .scaleEffect(0.8)
                                .padding(2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isBest {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Palette.gold.color)
                                .photoBadge()
                                .scaleEffect(0.8)
                                .padding(2)
                        }
                    }
                Text(verbatim: shortReason(photo, isBest: isBest))
                    .font(.system(size: 10.5, weight: reviewIds.contains(photo.id) ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    // « presque aussi bonne que DSC04311 » shrinks a little rather than losing the name.
                    .minimumScaleFactor(0.8)
                    .frame(width: Self.itemSize.width)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(photo.fileName)
        .accessibilityLabel(Text(verbatim: ReviewPhotoPane.spokenLabel(of: photo, isBest: isBest) + ", " + shortReason(photo, isBest: isBest)))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    /// « Meilleure », « presque aussi bonne que DSC04311 », « sujet un peu flou »…
    private func shortReason(_ photo: Photo, isBest: Bool) -> String {
        if isBest { return String(localized: "Meilleure") }
        if let reason = photo.cullingReasons.first(where: { $0.kind != .noIssue }) {
            return ViewerReasonLine.phrase(for: reason, hasSubject: photo.subjectBox != nil)
        }
        return photo.verdict?.label ?? String(localized: "pas encore triée")
    }
}

// MARK: - Sorting bar

/// Garder P · À revoir U · Rejeter X (| Meilleure B) for the photo shown, as the viewer's bar.
/// In the review a click moves on, like the key.
private struct ReviewSortingBar: View {
    let photo: Photo
    let isBest: Bool
    let showsBest: Bool
    let onSort: (SortingCommand) -> Void
    let onBest: () -> Void

    private static let verdicts: [CullingVerdict] = [.keep, .review, .reject]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.verdicts, id: \.self) { verdict in
                ViewerSegment(
                    title: verdict.label, key: SortingCommand.choose(verdict).key,
                    symbolName: verdict.symbolName, tint: verdict.tint, isOn: photo.verdict == verdict
                ) {
                    onSort(.choose(verdict))
                }
            }
            if showsBest {
                Rectangle()
                    .fill(Palette.line.color)
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
                ViewerSegment(
                    title: String(localized: "Meilleure"), key: "B", symbolName: "star.fill", tint: Palette.gold.color,
                    isOn: isBest, action: onBest
                )
            }
        }
        .padding(5)
        .glassBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Trier la photo montrée"))
    }
}

// MARK: - Summary

/// « Mettre les N photos rejetées à la corbeille… »: how many, and what opens the confirmation window.
struct TrashRejectedAction {
    var count: Int
    var perform: () -> Void
}

/// The end of the review: what became of the photos that were « À revoir ».
struct ReviewSummaryView: View {
    let summary: ReviewSummary
    let onClose: () -> Void
    let onReviewRemaining: () -> Void
    /// Nil hides the button.
    var trashRejected: TrashRejectedAction?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.accent.color)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Revue terminée")
                    .font(.system(size: 24, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("Sur les \(summary.total) photos qui étaient à revoir :")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                chip(.keep, ReviewText.kept(summary.kept))
                chip(.reject, ReviewText.rejected(summary.rejected))
                chip(.review, ReviewText.toReview(summary.toReview))
            }
            HStack(spacing: 12) {
                if summary.toReview > 0 {
                    Button(action: onReviewRemaining) {
                        Text(summary.toReview > 1 ? "Revoir les \(summary.toReview) restantes" : "Revoir la dernière")
                    }
                    .buttonStyle(.capsule())
                    .help("Une nouvelle revue des photos encore « À revoir »")
                }
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Text("Revenir aux photos")
                        ProminentKeyCap("↩")
                    }
                }
                .buttonStyle(.capsule(.prominent))
            }
            if let trashRejected, trashRejected.count > 0 {
                Button(role: .destructive, action: trashRejected.perform) {
                    Label(PhotoDeletionText.rejectedMenuTitle(count: trashRejected.count), systemImage: "trash")
                }
                .buttonStyle(.capsule(.destructive))
                .help("Toutes les photos de la galerie marquées Rejeter, par vous ou par l'IA. Une fenêtre demande confirmation ; vous pourrez annuler.")
            }
            Text("← : revenir à la dernière rafale · ⌘Z : annuler la dernière décision")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chip(_ verdict: CullingVerdict, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: verdict.symbolName)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(verdict.tint)
            Text(verbatim: text)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Palette.card.color, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line.color, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// A key cap on an accent-filled button: `KeyCap` draws dark text on a white cap, which the button's
/// white text colour would make invisible.
private struct ProminentKeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

// MARK: - Entry point

/// « ▶ Revoir les 14 » or « ▶ Reprendre la revue (reste 9) », next to the verdict filters.
struct ReviewEntryButton: View {
    /// How much of the title fits next to the filters.
    enum Style {
        /// « Reprendre la revue (reste 9) ».
        case full
        /// « Reprendre (9) ».
        case short
        /// « ▶ 9 »: the whole sentence stays in the tooltip and for VoiceOver.
        case compact
    }

    let entryPoint: ReviewEntryPoint
    var style = Style.full
    let action: () -> Void

    private var title: String {
        switch style {
        case .full: entryPoint.title
        case .short: entryPoint.shortTitle
        case .compact: entryPoint.count.formatted()
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.review.color)
                Text(verbatim: title)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .padding(3)
            .glassBackground()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(entryPoint.help)
        .accessibilityLabel(Text(verbatim: entryPoint.accessibilityLabel))
    }
}
