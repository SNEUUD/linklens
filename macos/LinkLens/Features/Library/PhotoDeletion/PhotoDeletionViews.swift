import SwiftUI

/// The photo deletion's window: the confirmation (« Mettre 12 photos à la corbeille ? »), or, after a
/// deletion where some files stayed where they were, the report. Same look as the gallery deletion.
struct PhotoDeletionSheet: View {
    @Environment(PhotoDeletionController.self) private var controller
    let cache: ThumbnailCache

    var body: some View {
        Group {
            if let request = controller.request {
                if case .markPending(let volumeName) = request.action {
                    PendingTrashForm(request: request, volumeName: volumeName, cache: cache)
                } else {
                    PhotoDeletionForm(request: request, cache: cache)
                }
            } else if let report = controller.report {
                PhotoDeletionReportView(report: report)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct PhotoDeletionForm: View {
    @Environment(PhotoDeletionController.self) private var controller
    let request: PhotoDeletionRequest
    let cache: ThumbnailCache

    var body: some View {
        let stamps = controller.stamps
        let missing = stamps.map { request.count - $0.count } ?? 0
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                systemImage: "trash",
                tint: Palette.reject,
                soft: Palette.rejectSoft,
                title: Text(verbatim: PhotoDeletionText.title(count: request.count, kind: request.kind)),
                subtitle: Text(verbatim: PhotoDeletionText.filesSummary(count: request.count, bytes: request.totalBytes))
            )

            PhotoTrashPreviewStrip(items: request.previews, total: request.count, cache: cache)

            if request.kind == .rejected {
                MessageBox(systemImage: "xmark.circle.fill", tint: Palette.reject, soft: Palette.rejectSoft) {
                    Text("Ce sont les photos marquées Rejeter, par vous ou par l'IA. Vérifiez-les d'abord avec le filtre Rejeter (⌘4) : l'IA peut se tromper.")
                }
            }

            if request.kind == .pending {
                MessageBox(systemImage: "clock", tint: Palette.review, soft: Palette.reviewSoft) {
                    Text("Ce sont les photos mises en attente pendant que le disque était débranché. Juste avant de déplacer chaque fichier, LinkLens vérifie qu'il est toujours dans le dossier de la galerie et qu'il a la taille relevée à l'import : un fichier modifié ou disparu reste à sa place.")
                }
            }

            MessageBox(systemImage: "arrow.uturn.backward.circle", tint: Palette.accent, soft: Palette.accentSoft) {
                Text("Les fichiers vont dans la corbeille du Finder : ils ne sont pas supprimés définitivement. Vous pourrez les remettre à leur place pendant 10 minutes (⌘Z ou « Annuler »), puis depuis la corbeille.")
            }

            MessageBox(systemImage: "exclamationmark.triangle.fill", tint: Palette.review, soft: Palette.reviewSoft) {
                Text("Les choix de tri de ces photos seront perdus : Garder, À revoir, Rejeter et meilleure photo de la rafale (ils reviennent si vous annulez).")
            }

            if missing > 0 {
                Text(missing > 1
                     ? "\(missing) fichiers sont introuvables ou ont changé depuis l'import : ils ne seront pas touchés."
                     : "1 fichier est introuvable ou a changé depuis l'import : il ne sera pas touché.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = controller.errorMessage {
                MessageBox(systemImage: "xmark.octagon.fill", tint: Palette.reject, soft: Palette.rejectSoft) {
                    Text(verbatim: error)
                }
            }

            HStack(spacing: 10) {
                // Secondary choice, on the left: the catalogue only, the files stay.
                Button("Retirer seulement de LinkLens", action: controller.removeFromLibraryOnly)
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .help("Retirer ces photos de LinkLens et garder les fichiers à leur place. Vous pourrez annuler.")
                    .accessibilityLabel(Text("Retirer seulement de LinkLens, garder les fichiers"))
                if stamps == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Vérification des fichiers")
                }
                Spacer()
                Button("Annuler", role: .cancel, action: controller.cancel)
                    .buttonStyle(.capsule(.secondary))
                    .keyboardShortcut(.cancelAction)
                // Not the default button (Return): a deletion is always a deliberate click. Enabled once
                // the files were looked at (their size and date are checked again right before the move).
                Button("Mettre à la corbeille", role: .destructive, action: controller.confirm)
                    .buttonStyle(.capsule(.destructive))
                    .disabled(stamps == nil)
                    .accessibilityLabel(Text(verbatim: PhotoDeletionText.title(count: request.count, kind: request.kind)
                        .replacingOccurrences(of: " ?", with: "")))
            }
        }
    }
}

/// The first photos as small thumbnails, and « +7 » for the others.
struct PhotoTrashPreviewStrip: View {
    let items: [PhotoTrashItem]
    let total: Int
    let cache: ThumbnailCache

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                PreviewThumbnail(item: item, cache: cache)
            }
            if total > items.count {
                Text(verbatim: "+\((total - items.count).formatted())")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 64)
                    .background(Palette.field.color, in: RoundedRectangle(cornerRadius: Radius.thumbnail))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: items.map(\.fileName).joined(separator: ", ")
            + (total > items.count ? String(localized: " et \(total - items.count) autres") : "")))
    }
}

private struct PreviewThumbnail: View {
    let item: PhotoTrashItem
    let cache: ThumbnailCache
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Palette.photoBackground.color
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.isVideo ? "video" : "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
        .help(item.fileName)
        // Read from the disk cache away from the interface (a few small JPEGs).
        .task(id: item.photoId) {
            let cache = cache
            let photoId = item.photoId
            image = await Task.detached { cache.image(for: photoId) }.value
        }
    }
}

/// After a deletion where files stayed in place: which ones and why, and « Retirer seulement de LinkLens ».
private struct PhotoDeletionReportView: View {
    @Environment(PhotoDeletionController.self) private var controller
    let report: PhotoDeletionReport

    /// More would make a very long window: the count says the rest.
    private static let listedLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                systemImage: "exclamationmark.triangle",
                tint: Palette.review,
                soft: Palette.reviewSoft,
                title: Text(verbatim: PhotoDeletionText.reportTitle(report)),
                subtitle: report.trashedCount > 0
                    ? Text(verbatim: PhotoDeletionText.trashedTitle(count: report.trashedCount) + String(localized: " (annulable)"))
                    : Text("Aucun fichier n'a été déplacé.")
            )

            if report.trashWasRefused {
                MessageBox(systemImage: "externaldrive.badge.exclamationmark", tint: Palette.review, soft: Palette.reviewSoft) {
                    Text("Ce disque n'a peut-être pas de corbeille (format exFAT ou FAT, disque réseau). LinkLens ne supprime jamais un fichier définitivement à la place de la corbeille : ces fichiers n'ont pas bougé. Vous pouvez les retirer de LinkLens en gardant les fichiers, puis les supprimer vous-même depuis le Finder.")
                }
            }

            if report.keepsPendingMarks {
                MessageBox(systemImage: "clock", tint: Palette.review, soft: Palette.reviewSoft) {
                    Text("Les photos restées à leur place restent en attente de corbeille, jusqu'à ce que vous choisissiez : « Retirer seulement de LinkLens » ici, ou « Retirer de l'attente » au-dessus des photos.")
                }
            }

            if report.notReachedCount > 0 {
                Text(report.notReachedCount > 1
                     ? "Interrompue : \(report.notReachedCount) photos n'ont pas été touchées et restent dans LinkLens."
                     : "Interrompue : 1 photo n'a pas été touchée et reste dans LinkLens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !report.skipped.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(report.skipped.prefix(Self.listedLimit)) { skipped in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: skipped.item.relativePath)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(verbatim: skipped.reason.message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if report.skipped.count > Self.listedLimit {
                            Text("et \(report.skipped.count - Self.listedLimit) autres")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fieldBox()
                .accessibilityLabel(Text("Fichiers restés à leur place"))
            }

            HStack(spacing: 10) {
                Spacer()
                if !report.skipped.isEmpty {
                    Button("Retirer seulement de LinkLens (garder les fichiers)", action: controller.removeSkippedFromLibrary)
                        .buttonStyle(.capsule(.secondary))
                        .help("Ces photos quittent LinkLens ; leurs fichiers restent où ils sont. Vous pourrez annuler.")
                }
                Button("Fermer", action: controller.dismissReport)
                    .buttonStyle(.capsule(.prominent))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// The glass banner over the photos after a deletion (« Annuler ») or an undo.
struct PhotoDeletionBannerView: View {
    let banner: PhotoDeletionBanner
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.canUndo ? "trash" : "arrow.uturn.backward.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(banner.canUndo ? Palette.reject.color : Palette.keep.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: banner.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let detail = banner.detail {
                    Text(verbatim: detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if banner.canUndo {
                Button("Annuler", action: onUndo)
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .help("Remettre les photos à leur place (⌘Z)")
                    .accessibilityLabel(Text("Annuler : remettre les photos"))
            }
            Button("Fermer", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Masquer ce message")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .glassBackground(in: RoundedRectangle(cornerRadius: Radius.panel))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suppression de photos")
    }
}

/// The inspector while several photos are selected: how many, their size, a few thumbnails, their
/// verdicts, and « Mettre à la corbeille… ».
struct PhotoSelectionSummary: View {
    /// The selected photos, in display order.
    let photos: [Photo]
    let loader: ThumbnailLoader
    /// Nil while the photos cannot be put in the trash (`trashHelp` says why).
    let onTrash: (() -> Void)?
    let trashHelp: String
    /// The disk is unplugged: the button only marks the photos as waiting for the trash.
    var marksPending = false
    /// « Retirer de l'attente de corbeille », nil when none of these photos is waiting.
    var onUnmark: (() -> Void)? = nil

    var body: some View {
        let counts = VerdictCounts(photos)
        let pendingCount = photos.filter(\.isPendingTrash).count
        let bytes = photos.reduce(0) { $0 + $1.fileSize }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PhotoDeletionText.selectedTitle(count: photos.count))
                        .font(.system(size: 14, weight: .bold))
                    Text(verbatim: PhotoDeletionText.filesSummary(count: photos.count, bytes: bytes))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                // `LazyVGrid` with 3 flexible columns, like a CSS grid `repeat(3, 1fr)`.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(photos.prefix(9)) { photo in
                        SummaryThumbnail(photo: photo, loader: loader)
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach([CullingVerdict.keep, .review, .reject], id: \.self) { verdict in
                        let count = counts.count(of: verdict)
                        if count > 0 {
                            HStack(spacing: 8) {
                                Image(systemName: verdict.symbolName)
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(verdict.tint)
                                    .frame(width: 14)
                                Text(verbatim: "\(verdict.label) · \(count.formatted())")
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Text("P, U ou X trie toutes ces photos d'un coup ; ⌘Z annule. Échap désélectionne.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
                    onTrash?()
                } label: {
                    Label(PhotoDeletionText.trashMenuTitle(count: photos.count, pending: marksPending), systemImage: "trash")
                }
                .buttonStyle(.capsule(.destructive))
                .disabled(onTrash == nil)
                .help(trashHelp)

                if pendingCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(PhotoDeletionText.pendingCount(pendingCount), systemImage: "trash")
                            .foregroundStyle(Palette.review.color)
                        if let onUnmark {
                            Button(PhotoDeletionText.unmarkMenuTitle(count: pendingCount), action: onUnmark)
                                .buttonStyle(.capsule(.secondary, size: .small))
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct SummaryThumbnail: View {
    let photo: Photo
    let loader: ThumbnailLoader
    @State private var image: CGImage?

    var body: some View {
        let shown = image ?? loader.cachedThumbnail(for: photo.id)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Palette.photoBackground.color
                    if let shown {
                        Image(decorative: shown, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: photo.id) {
                if loader.cachedThumbnail(for: photo.id) == nil {
                    image = await loader.thumbnail(for: photo.thumbnailRequest)
                }
            }
    }
}
