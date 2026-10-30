import SwiftUI

// The floating controls of the viewer, on glass as in the mockup: ‹ ›, the AI's reason, the sorting bar
// and the filmstrip. They receive plain values and closures; `PhotoViewer` wires them.

// MARK: - ‹ ›

struct ViewerArrowButton: View {
    let isNext: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isNext ? "chevron.right" : "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassBackground(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(isNext ? "Photo suivante (→)" : "Photo précédente (←)")
        .accessibilityLabel(isNext ? Text("Photo suivante, touche flèche droite") : Text("Photo précédente, touche flèche gauche"))
    }
}

// MARK: - The AI's reason

/// « L'IA propose Garder : meilleure photo de la rafale, sujet net et entier. » in a glass pill, with
/// « Revenir à l'IA A » after a choice of the user.
struct ViewerReasonPill: View {
    let line: ViewerReasonLine
    let onFollowAI: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            icon
                .font(.system(size: 12, weight: .bold))
                .accessibilityHidden(true)
            (Text(verbatim: line.lead).fontWeight(.semibold) + Text(verbatim: line.rest))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityLabel(Text(verbatim: line.text))
            if line.canFollowAI {
                Button(action: onFollowAI) {
                    HStack(spacing: 4) {
                        Text("Revenir à l'IA")
                        KeyCap("A")
                    }
                }
                .buttonStyle(.link)
                .help("Oublier votre choix : la proposition de l'IA s'applique de nouveau (A)")
                .accessibilityLabel(Text("Revenir à la proposition de l'IA, touche A"))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassBackground()
        .frame(maxWidth: 760)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch line.icon {
        case .star:
            Image(systemName: "star.fill").foregroundStyle(Palette.gold.color)
        case .verdict(let verdict):
            Image(systemName: verdict.symbolName).foregroundStyle(verdict.tint)
        case .person:
            Image(systemName: "person.fill").foregroundStyle(.secondary)
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sorting bar

/// Garder P · À revoir U · Rejeter X | Meilleure B · Replier la rafale S, the current state highlighted.
/// A click does not move to the next photo; the keys do (as in the grid).
struct ViewerSortingBar: View {
    let photo: Photo
    let burst: BurstPlacement?
    let onSort: (SortingCommand) -> Void
    let onBurstCover: () -> Void
    let onToggleBurst: () -> Void

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
            if let burst {
                Rectangle()
                    .fill(Palette.line.color)
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
                ViewerSegment(
                    title: String(localized: "Meilleure"), key: "B", symbolName: "star.fill", tint: Palette.gold.color,
                    isOn: burst.showsStar(isBestOfBurst: photo.isBestOfBurst), action: onBurstCover
                )
                ViewerSegment(
                    title: burst.isExpanded && !burst.isShownAlone ? String(localized: "Replier la rafale") : String(localized: "Voir la rafale"),
                    key: "S", symbolName: nil, tint: .primary, isOn: false, action: onToggleBurst
                )
            }
        }
        .padding(5)
        .glassBackground()
        // Like a `role="group"` with an `aria-label`.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Trier cette photo"))
    }
}

/// One button of the sorting bar: symbol, word and key; tinted on a soft background when it is the
/// photo's current state. Also used by the review's bar.
struct ViewerSegment: View {
    let title: String
    let key: String
    let symbolName: String?
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(tint)
                }
                Text(verbatim: title)
                    .fontWeight(isOn ? .semibold : .medium)
                    .foregroundStyle(isOn ? tint : Color.primary)
                    .lineLimit(1)
                KeyCap(key)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background {
                if isOn { Capsule().fill(tint.opacity(0.16)) }
            }
            // The whole segment reacts to a click, not only its text.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(key))")
        // VoiceOver: « Garder, touche P, sélectionné, bouton ».
        .accessibilityLabel(Text(verbatim: String(localized: "\(title), touche \(key)")))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Filmstrip

/// The thumbnails at the bottom: the open burst (« Rafale 4 » between lines) or the neighbouring photos,
/// with the photo or burst before and after dimmed. A click shows the photo.
struct ViewerFilmstrip: View {
    let strip: Filmstrip
    let photosById: [UUID: Photo]
    let selection: UUID
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    let itemSize: CGSize
    let onSelect: (UUID) -> Void

    static let itemHeight: CGFloat = 78
    static let dimmedHeight: CGFloat = 72

    var body: some View {
        HStack(spacing: 8) {
            if let leading = strip.leading {
                dimmed(leading, isBefore: true)
                separator(burstNumber: strip.burstNumber)
            }
            ForEach(strip.items) { entry in
                item(entry)
            }
            if let trailing = strip.trailing {
                separator(burstNumber: nil)
                dimmed(trailing, isBefore: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackground(in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Pellicule"))
    }

    @ViewBuilder
    private func item(_ entry: GalleryEntry) -> some View {
        if let photo = photosById[entry.photoId] {
            let isSelected = entry.photoId == selection
            Button {
                onSelect(entry.photoId)
            } label: {
                VStack(spacing: 5) {
                    FilmstripThumbnail(photo: photo, loader: loader, canUseOriginals: canUseOriginals, size: itemSize)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Radius.small + 1.25)
                                    .stroke(Color.accentColor, lineWidth: 2.5)
                                    .padding(-1.25)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if let burst = entry.burst, burst.showsStar(isBestOfBurst: photo.isBestOfBurst) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Palette.gold.color)
                                    .frame(width: 16, height: 16)
                                    .background(Palette.badge.color, in: Circle())
                                    .padding(4)
                            }
                        }
                    Circle()
                        .fill(photo.verdict?.tint ?? Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(entry.isOutsideFilter ? 0.45 : 1)
            .help(photo.fileName)
            .accessibilityLabel(Text(verbatim: label(for: photo, entry: entry)))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func dimmed(_ entry: GalleryEntry, isBefore: Bool) -> some View {
        let photo = photosById[entry.photoId]
        let width = (Self.dimmedHeight * itemSize.width / itemSize.height).rounded()
        return Button {
            onSelect(entry.photoId)
        } label: {
            Group {
                if let photo {
                    FilmstripThumbnail(photo: photo, loader: loader, canUseOriginals: canUseOriginals, size: CGSize(width: width, height: Self.dimmedHeight))
                } else {
                    Color.clear.frame(width: width, height: Self.dimmedHeight)
                }
            }
            .opacity(0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(photo?.fileName ?? "")
        .accessibilityLabel(Text(verbatim: dimmedLabel(photo: photo, entry: entry, isBefore: isBefore)))
    }

    /// A line, with « Rafale 4 » across it before the photos of an open burst.
    @ViewBuilder
    private func separator(burstNumber: Int?) -> some View {
        if let burstNumber {
            VStack(spacing: 2) {
                Rectangle().fill(Palette.line.color).frame(width: 1, height: 22)
                Text("Rafale \(burstNumber)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(Palette.line.color).frame(width: 1, height: 22)
            }
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(Palette.line.color)
                .frame(width: 1, height: 48)
                .padding(.horizontal, 6)
                .accessibilityHidden(true)
        }
    }

    /// « DSC04307, À revoir, meilleure de la rafale ».
    private func label(for photo: Photo, entry: GalleryEntry) -> String {
        var parts = [(photo.fileName as NSString).deletingPathExtension]
        parts.append(photo.verdictDescription ?? String(localized: "pas encore triée"))
        if let burst = entry.burst, burst.showsStar(isBestOfBurst: photo.isBestOfBurst) {
            parts.append(burst.starDescription)
        }
        return parts.joined(separator: ", ")
    }

    /// « Avant : DSC04304, rafale de 5 photos ».
    private func dimmedLabel(photo: Photo?, entry: GalleryEntry, isBefore: Bool) -> String {
        let name = photo.map { ($0.fileName as NSString).deletingPathExtension } ?? ""
        var text = isBefore ? String(localized: "Avant : \(name)") : String(localized: "Après : \(name)")
        if let burst = entry.burst, burst.number != strip.burstNumber {
            text += ", " + burst.accessibilityDescription
        }
        return text
    }
}

/// One thumbnail of the filmstrip (and of the review's burst strip): the cached thumbnail, generated if
/// needed, filling its frame.
struct FilmstripThumbnail: View {
    let photo: Photo
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    let size: CGSize
    @State private var loadedImage: CGImage?

    var body: some View {
        let image = loadedImage ?? loader.cachedThumbnail(for: photo.id)
        ZStack {
            Palette.photoBackground.color
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
        .task(id: TaskKey(photoId: photo.id, canUseOriginals: canUseOriginals)) {
            if let cached = loader.cachedThumbnail(for: photo.id) {
                loadedImage = cached
            } else {
                loadedImage = await loader.thumbnail(for: photo.thumbnailRequest)
            }
        }
    }

    private struct TaskKey: Hashable {
        var photoId: UUID
        var canUseOriginals: Bool
    }
}
