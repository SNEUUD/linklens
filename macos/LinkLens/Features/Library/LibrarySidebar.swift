import SwiftData
import SwiftUI

extension EnvironmentValues {
    /// Where the thumbnails are read from. The app uses the standard cache; the interface renders
    /// of the tests pass a temporary one. `@Entry` declares an environment value with its default,
    /// like `createContext(defaultValue)` in React.
    @Entry var thumbnailCache: ThumbnailCache = .standard
}

/// The sidebar: galleries (cover, counts, verdict bar), the detected cards, the tools, and the
/// privacy promise at the bottom. It receives plain values rather than the controllers, so the
/// tests can draw it in every state (indexing, disk unplugged, card inserted).
struct LibrarySidebar: View {
    let galleries: [Gallery]
    @Binding var selection: UUID?
    var indexing: IndexingProgress?
    var onCancelIndexing: () -> Void = {}
    /// F9: whether each gallery's originals can be read now.
    var availability: (UUID) -> GalleryAvailability = { _ in .available }
    var cards: [DetectedCard] = []
    var onImportCard: (DetectedCard) -> Void = { _ in }
    var onDismissCard: (DetectedCard) -> Void = { _ in }
    var onShowDuplicates: () -> Void = {}
    /// « Supprimer la galerie… » in a row's right-click menu, and whether it is possible now.
    var onDeleteGallery: (Gallery) -> Void = { _ in }
    var canDeleteGallery: (UUID) -> Bool = { _ in false }

    var body: some View {
        List(selection: $selection) {
            Section("Galeries") {
                ForEach(galleries) { gallery in
                    GallerySidebarRow(
                        gallery: gallery,
                        availability: availability(gallery.id),
                        indexing: indexing?.galleryId == gallery.id ? indexing : nil,
                        onCancelIndexing: onCancelIndexing
                    )
                    .tag(gallery.id)
                    // The right-click menu of the row (like `onContextMenu` in React, but drawn by macOS).
                    .contextMenu {
                        Button("Supprimer la galerie…", systemImage: "trash", role: .destructive) {
                            onDeleteGallery(gallery)
                        }
                        .disabled(!canDeleteGallery(gallery.id))
                        .accessibilityLabel(Text("Supprimer la galerie « \(gallery.name) »…"))
                    }
                }
                if galleries.isEmpty {
                    // First launch: where the sessions will go. The welcome screen next to it has the
                    // buttons, so « Ajouter une galerie… » and the tools only come with the first gallery.
                    Text("Vos séances apparaîtront ici, avec leur couverture et l'avancement du tri.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .lineLimit(2...4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.regular)
                        .padding(.vertical, Spacing.large)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.card)
                                .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                        .padding(.vertical, Spacing.xSmall)
                } else {
                    AddGalleryButton()
                }
            }

            if !cards.isEmpty {
                Section("Carte détectée") {
                    ForEach(cards) { card in
                        DetectedCardRow(card: card) {
                            onImportCard(card)
                        } onDismiss: {
                            onDismissCard(card)
                        }
                    }
                }
            }

            if !galleries.isEmpty {
                Section("Outils") {
                    Button(action: onShowDuplicates) {
                        HStack(spacing: Spacing.regular) {
                            Image(systemName: "square.on.square")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                                Text("Doublons")
                                    .fontWeight(.medium)
                                Text("Dans toutes les galeries")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rechercher les fichiers identiques dans toutes vos galeries")
                    .accessibilityLabel("Doublons dans toutes les galeries")
                }
            }
        }
        .listStyle(.sidebar)
        // `safeAreaInset` pins a view under the list without covering its last rows.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // No `.fixedSize` here: measured at a tiny width, the text would ask for one word per line
            // and the window could no longer be made shorter than the screen.
            Text("Vos photos restent sur ce Mac. L'IA propose, rien n'est supprimé sans vous.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.regular)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }
}

/// « + Ajouter une galerie… » under the galleries: a popover with the two ways to add one.
/// (A `Menu` here drew its « + » dark on dark in dark mode.)
private struct AddGalleryButton: View {
    @Environment(ImportController.self) private var importController
    @Environment(CardImportController.self) private var cardImportController
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Ajouter une galerie…", systemImage: "plus")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Importer une carte SD ou ajouter un dossier de photos")
        // `.popover` shows a bubble attached to the button while the Boolean is true.
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                choice("Importer une carte SD…", systemImage: "sdcard", detail: "Copier puis vérifier chaque fichier") {
                    cardImportController.chooseCard()
                }
                .disabled(cardImportController.isSheetPresented)
                choice("Ajouter un dossier…", systemImage: "folder", detail: "Les fichiers restent à leur place") {
                    importController.chooseFolder()
                }
                .disabled(importController.isIndexing)
            }
            .padding(Spacing.medium)
        }
    }

    private func choice(_ title: LocalizedStringKey, systemImage: String, detail: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            HStack(spacing: Spacing.regular) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One gallery: cover, name, « 52 photos · 12 rafales », verdict bar, F9 icon, indexing progress.
private struct GallerySidebarRow: View {
    let gallery: Gallery
    let availability: GalleryAvailability
    let indexing: IndexingProgress?
    let onCancelIndexing: () -> Void
    @Query private var photos: [Photo]

    init(gallery: Gallery, availability: GalleryAvailability, indexing: IndexingProgress?, onCancelIndexing: @escaping () -> Void) {
        self.gallery = gallery
        self.availability = availability
        self.indexing = indexing
        self.onCancelIndexing = onCancelIndexing
        let galleryId = gallery.id
        // Same order as the gallery itself, so « the first photo » is the same everywhere.
        _photos = Query(
            filter: #Predicate<Photo> { $0.gallery?.id == galleryId },
            sort: [SortDescriptor(\.captureDate), SortDescriptor(\.relativePath)]
        )
    }

    var body: some View {
        let summary = GallerySummary(photos.map(\.summaryItem))
        HStack(spacing: Spacing.regular) {
            GalleryCover(candidates: summary.coverCandidates, photoCount: photos.count)
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                HStack(spacing: Spacing.small) {
                    Text(gallery.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if !availability.canUseOriginals {
                        Image(systemName: availability.systemImage)
                            .foregroundStyle(Palette.review.color)
                            .help(availability.message ?? "")
                            .accessibilityLabel(availability.message ?? "")
                    }
                }
                // `if let` unwraps an optional: the block only runs when `indexing` is not nil
                // (like `if (indexing != null)` in TypeScript, with `indexing` typed non-null inside).
                if let indexing {
                    ProgressView(value: indexing.fraction)
                        .controlSize(.small)
                    HStack {
                        Text("Indexation : \(indexing.completed) sur \(indexing.total)")
                            .monospacedDigit()
                        Spacer(minLength: Spacing.xSmall)
                        Button("Annuler", action: onCancelIndexing)
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Group {
                        if let message = availability.message {
                            Text(message)
                                .lineLimit(2)
                        } else {
                            countsText(summary)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if gallery.culledAt != nil || summary.isSorted {
                        VerdictBar(summary: summary)
                    }
                    let pendingCount = photos.count { $0.isPendingTrash }
                    if pendingCount > 0 {
                        // An `HStack` rather than a `Label`: in a sidebar, a label's icon takes the accent colour.
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "trash")
                            Text(verbatim: PhotoDeletionText.pendingShort(pendingCount))
                        }
                        .font(.caption)
                        .foregroundStyle(Palette.review.color)
                        .lineLimit(1)
                        .help(PendingTrashText.badgeHelp)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xSmall)
        // VoiceOver reads the row as one item: name, counts, verdicts, disk.
        .accessibilityElement(children: .combine)
    }

    private func countsText(_ summary: GallerySummary) -> Text {
        // `^[…](inflect: true)` lets Foundation write « 1 photo » / « 2 photos » for us.
        var text = Text("^[\(summary.photoCount) photo](inflect: true)")
        if summary.videoCount > 0 {
            text = text + Text(verbatim: " · ") + Text("^[\(summary.videoCount) vidéo](inflect: true)")
        }
        if summary.burstCount > 0 {
            text = text + Text(verbatim: " · ") + Text("^[\(summary.burstCount) rafale](inflect: true)")
        }
        return text
    }
}

/// Thin bar of the verdicts: green, orange, red, then grey for the photos not sorted yet.
/// Includes the user's own choices (it counts `Photo.verdict`).
struct VerdictBar: View {
    let summary: GallerySummary

    var body: some View {
        // `GeometryReader` gives the size offered by the parent (like measuring a div with a ResizeObserver).
        GeometryReader { geometry in
            let segments = summary.verdictSegments
            let total = segments.reduce(0) { $0 + $1.count }
            let gaps = CGFloat(max(segments.count - 1, 0))
            HStack(spacing: 1) {
                ForEach(segments, id: \.verdict) { segment in
                    Rectangle()
                        .fill(segment.verdict?.tint ?? Color.secondary.opacity(0.3))
                        .frame(width: total == 0 ? 0 : (geometry.size.width - gaps) * CGFloat(segment.count) / CGFloat(total))
                }
            }
        }
        .frame(height: SidebarMetrics.verdictBarHeight)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(summary.verdictBarDescription)
    }
}

/// Square cover of a gallery from the thumbnail cache: the best photo whose thumbnail is made.
private struct GalleryCover: View {
    let candidates: [UUID]
    /// Looks again when photos are added (indexing): their thumbnails may be ready by then.
    let photoCount: Int
    @Environment(\.thumbnailCache) private var cache
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.cover)
                .fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: SidebarMetrics.coverSize, height: SidebarMetrics.coverSize)
        .clipShape(RoundedRectangle(cornerRadius: Radius.cover))
        .accessibilityHidden(true)
        .task(id: CoverKey(candidates: candidates, photoCount: photoCount)) {
            image = await Self.loadCover(candidates: candidates, cache: cache)
        }
    }

    /// Reads the cache folder once, then decodes one small JPEG, away from the main thread.
    /// `@concurrent` runs the function on a background thread even when called from the interface.
    @concurrent
    private static func loadCover(candidates: [UUID], cache: ThumbnailCache) async -> CGImage? {
        let missing = Set(cache.missing(among: candidates))
        let cached = Set(candidates.filter { !missing.contains($0) })
        guard let photoId = GallerySummary.cover(among: candidates, cached: cached) else { return nil }
        return cache.image(for: photoId)
    }
}

private struct CoverKey: Hashable {
    var candidates: [UUID]
    var photoCount: Int
}

/// A camera card just inserted, with « Importer… » and a button to hide it (F1).
struct DetectedCardRow: View {
    let card: DetectedCard
    let onImport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "sdcard")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(verbatim: card.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("Carte SD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.xSmall)
            Button("Importer…", action: onImport)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help("Copier les photos et vidéos de la carte dans une nouvelle galerie")
            Button("Ignorer", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Masquer jusqu'à la prochaine insertion de la carte")
        }
        .padding(Spacing.regular)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Carte détectée : \(card.name)"))
    }
}
