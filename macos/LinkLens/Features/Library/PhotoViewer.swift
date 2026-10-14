import SwiftUI

/// Large view of the selected photo, with the AI verdict and all its reasons.
/// ← → go to the previous / next photo; space or Escape go back.
struct PhotoViewer: View {
    let photos: [Photo]
    /// Index of the photo shown in `photos`.
    let index: Int
    let loader: ThumbnailLoader
    let browser: GalleryBrowser
    @State private var preview: LoadedImage?
    @State private var thumbnail: LoadedImage?
    @FocusState private var isFocused: Bool

    /// An image and the photo it belongs to, so a late image never shows under another photo.
    private struct LoadedImage {
        var photoId: UUID
        var image: CGImage
    }

    var body: some View {
        let photo = photos[index]
        VStack(spacing: 0) {
            imageArea(for: photo)
            Divider()
            PhotoInfoPanel(photo: photo, position: index + 1, total: photos.count)
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
        .task(id: photo.id) { await load(photo) }
    }

    private func imageArea(for photo: Photo) -> some View {
        // The full preview when it is loaded, the grid thumbnail meanwhile (or when the disk is unplugged).
        let image = [preview, thumbnail].compactMap { $0 }.first { $0.photoId == photo.id }?.image
            ?? loader.cachedThumbnail(for: photo.id)
        return ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                ProgressView()
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
            arrowButton("Photo suivante", systemImage: "chevron.right.circle.fill", disabled: index == photos.count - 1) {
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
        for neighbour in [index + 1, index - 1] where photos.indices.contains(neighbour) {
            guard !Task.isCancelled else { return }
            _ = await loader.preview(for: photos[neighbour].thumbnailRequest)
        }
    }
}

/// Under the image: file, date, position, verdict with the star, and every reason.
private struct PhotoInfoPanel: View {
    let photo: Photo
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
