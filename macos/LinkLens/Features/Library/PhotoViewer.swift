import SwiftUI

/// Large view of the selected photo, with the AI verdict and all its reasons.
/// ← → go to the previous / next shown photo (a collapsed burst counts as one); S opens or closes
/// the burst and B makes the photo its best one; space or Escape go back. P / U / X sort the photo
/// by hand and show the next one; A goes back to the AI's proposal.
struct PhotoViewer: View {
    let rows: [DisplayedPhoto]
    /// Index of the photo shown in `rows`.
    let index: Int
    let loader: ThumbnailLoader
    let browser: GalleryBrowser
    let sorter: ManualSorter
    /// Disk unplugged (F9): the largest image in memory or in the cache is shown, with a notice.
    var availability: GalleryAvailability = .available
    @State private var preview: LoadedImage?
    @State private var thumbnail: LoadedImage?
    @FocusState private var isFocused: Bool

    /// An image and the photo it belongs to, so a late image never shows under another photo.
    private struct LoadedImage {
        var photoId: UUID
        var image: CGImage
    }

    var body: some View {
        let photo = rows[index].photo
        VStack(spacing: 0) {
            imageArea(for: photo)
            Divider()
            PhotoInfoPanel(
                photo: photo, burst: rows[index].entry.burst, position: index + 1, total: rows.count,
                onSort: { command in sorter.apply(command, to: [photo.id]) },
                onBurstCover: { command in sorter.apply(command, to: photo.id) }
            )
        }
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .defaultFocus($isFocused, true)
        .task { isFocused = true }
        // The handlers only call `browser`, which always knows the photo shown now.
        .onKeyPress(.leftArrow) {
            browser.showNeighbour(offset: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            browser.showNeighbour(offset: 1)
            return .handled
        }
        .onKeyPress(keys: [.space, .escape]) { _ in
            browser.closeViewer()
            return .handled
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
        // Again when the disk comes back (F9): the full preview replaces the cached thumbnail.
        .task(id: LoadKey(photoId: photo.id, canUseOriginals: availability.canUseOriginals)) { await load(photo) }
    }

    private struct LoadKey: Hashable {
        var photoId: UUID
        var canUseOriginals: Bool
    }

    private func imageArea(for photo: Photo) -> some View {
        // The full preview when it is loaded, the grid thumbnail meanwhile (or when the disk is unplugged).
        let loadedPreview = preview?.photoId == photo.id ? preview?.image : nil
        let image = loadedPreview
            ?? (thumbnail?.photoId == photo.id ? thumbnail?.image : nil)
            ?? loader.cachedThumbnail(for: photo.id)
        return ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if !availability.canUseOriginals {
                // No thumbnail was made while the disk was there: nothing to show, but no endless spinner either.
                ContentUnavailableView("Pas de miniature en cache", systemImage: "photo")
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if let message = availability.message, loadedPreview == nil {
                Label("Aperçu réduit : \(message)", systemImage: availability.systemImage)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(16)
                    .help("Les fichiers originaux ne sont pas accessibles : LinkLens montre la plus grande image gardée en cache.")
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Retour", systemImage: "chevron.left", action: browser.closeViewer)
                .padding(12)
                .help("Revenir aux photos (Espace ou Échap)")
        }
        .overlay(alignment: .leading) {
            arrowButton("Photo précédente", systemImage: "chevron.left.circle.fill", disabled: index == 0) {
                browser.showNeighbour(offset: -1)
            }
        }
        .overlay(alignment: .trailing) {
            arrowButton("Photo suivante", systemImage: "chevron.right.circle.fill", disabled: index == rows.count - 1) {
                browser.showNeighbour(offset: 1)
            }
        }
    }

    private func arrowButton(_ title: LocalizedStringKey, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(disabled ? 0.15 : 0.6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(16)
        .help(title)
    }

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

/// Under the image: file, date, position, burst, the verdict with the star, the buttons to sort by hand,
/// and every reason of the AI (still shown when the user chose another verdict).
private struct PhotoInfoPanel: View {
    let photo: Photo
    let burst: BurstPlacement?
    let position: Int
    let total: Int
    let onSort: (SortingCommand) -> Void
    let onBurstCover: (BurstCoverCommand) -> Void

    var body: some View {
        let messages = photo.cullingReasons.map { $0.message() }
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: photo.relativePath)
                    .font(.headline)
                if let captureDate = photo.captureDate {
                    Text(captureDate, format: .dateTime.day().month(.wide).year().hour().minute().second())
                        .foregroundStyle(.secondary)
                }
                Text("Photo \(position) sur \(total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let burst {
                    Text(burst.isExpanded
                        ? "Rafale \(burst.number) · \(burst.count) photos (S pour replier)"
                        : "Rafale \(burst.number) · \(burst.count) photos (S pour toutes les voir)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    BurstCoverButtons(burst: burst, showsKeys: true, action: onBurstCover)
                        .buttonStyle(.link)
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VerdictBadge(verdict: photo.verdict, isChosenByUser: photo.isVerdictChosenByUser)
                        .font(.headline)
                    if photo.isVerdictChosenByUser {
                        Text("Votre choix")
                            .foregroundStyle(.secondary)
                    }
                    if let burst, burst.showsStar(isBestOfBurst: photo.isBestOfBurst) {
                        Label(burst.starDescription, systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                if photo.isVerdictChosenByUser, let proposal = photo.cullingVerdict {
                    Text("Proposition de l'IA : \(proposal.label)")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(verbatim: "• \(message)")
                }
            }
            Spacer(minLength: 0)
            SortingControls(photo: photo, onSort: onSort)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// Three buttons to sort the shown photo by hand, and one to go back to the AI's proposal.
/// The current verdict is highlighted. A click does not move to the next photo; the keys do.
private struct SortingControls: View {
    let photo: Photo
    let onSort: (SortingCommand) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                ForEach([CullingVerdict.keep, .review, .reject], id: \.self) { verdict in
                    verdictButton(verdict, isCurrent: photo.verdict == verdict)
                }
            }
            Button("Revenir à la proposition de l'IA (A)") { onSort(.followAI) }
                .buttonStyle(.link)
                .disabled(!photo.isVerdictChosenByUser)
                .help("Oublier votre choix : le verdict proposé par l'IA s'applique à nouveau")
        }
    }

    /// The current verdict is filled with its colour (`.borderedProminent`), the others only outlined.
    @ViewBuilder
    private func verdictButton(_ verdict: CullingVerdict, isCurrent: Bool) -> some View {
        let button = Button {
            onSort(.choose(verdict))
        } label: {
            Label(verdict.label, systemImage: verdict.symbolName)
        }
        .tint(verdict.color)
        .help("\(verdict.label) (\(SortingCommand.choose(verdict).key))")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        if isCurrent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
