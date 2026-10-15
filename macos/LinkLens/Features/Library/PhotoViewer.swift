import SwiftUI

/// Large view of the selected photo, with the AI verdict and all its reasons.
/// ← → go to the previous / next shown photo (a collapsed burst counts as one); S opens or closes
/// the burst; space or Escape go back.
struct PhotoViewer: View {
    let rows: [DisplayedPhoto]
    /// Index of the photo shown in `rows`.
    let index: Int
    let loader: ThumbnailLoader
    let browser: GalleryBrowser
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
            PhotoInfoPanel(photo: photo, burst: rows[index].entry.burst, position: index + 1, total: rows.count)
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

/// Under the image: file, date, position, burst, verdict with the star, and every reason.
private struct PhotoInfoPanel: View {
    let photo: Photo
    let burst: BurstPlacement?
    let position: Int
    let total: Int

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
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VerdictBadge(verdict: photo.cullingVerdict)
                        .font(.headline)
                    if photo.isBestOfBurst {
                        Label("Meilleure photo de la rafale", systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(verbatim: "• \(message)")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
