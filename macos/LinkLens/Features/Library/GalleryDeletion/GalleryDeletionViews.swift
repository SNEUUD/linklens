import SwiftUI

/// « Supprimer « Séance du 20 sept. » de LinkLens ? »: what is lost, the box to put the folder in the
/// trash too (unticked by default, greyed out with the reason when a safeguard says no), « Annuler »
/// (Escape) and « Supprimer ». Same look as the card import window.
struct GalleryDeletionSheet: View {
    @Environment(GalleryDeletionController.self) private var controller

    var body: some View {
        if let request = controller.request {
            GalleryDeletionForm(request: request)
                .padding(24)
                .frame(width: 540)
                .interactiveDismissDisabled(controller.isDeleting)
        }
    }
}

private struct GalleryDeletionForm: View {
    @Environment(GalleryDeletionController.self) private var controller
    let request: GalleryDeletionRequest

    var body: some View {
        // `@Bindable` gives a two-way binding (`$controller.alsoTrashFolder`) to an `@Observable` object.
        @Bindable var controller = controller

        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(
                systemImage: "trash",
                tint: Palette.reject,
                soft: Palette.rejectSoft,
                title: Text("Supprimer « \(request.name) » de LinkLens ?"),
                subtitle: Text(verbatim: GalleryDeletionText.contents(photoCount: request.photoCount, videoCount: request.videoCount))
            )

            MessageBox(systemImage: "exclamationmark.triangle.fill", tint: Palette.review, soft: Palette.reviewSoft) {
                Text("Les choix de tri de cette galerie seront perdus : Garder, À revoir, Rejeter et les meilleures photos des rafales. Les fichiers ne sont pas touchés, sauf si vous cochez la case ci-dessous.")
            }

            FolderTrashBox(request: request, check: controller.folderCheck, isOn: $controller.alsoTrashFolder)
                .disabled(controller.isDeleting)

            Text(controller.alsoTrashFolder
                 ? "Vous pourrez annuler pendant 10 minutes (⌘Z). Après, le dossier pourra encore être remis depuis la corbeille du Finder."
                 : "Vous pourrez annuler pendant 10 minutes (⌘Z).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = controller.errorMessage {
                MessageBox(systemImage: "xmark.octagon.fill", tint: Palette.reject, soft: Palette.rejectSoft) {
                    Text(verbatim: error)
                }
            }

            HStack(spacing: 10) {
                if controller.isDeleting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Suppression en cours")
                }
                Spacer()
                Button("Annuler", role: .cancel, action: controller.cancel)
                    .buttonStyle(.capsule(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(controller.isDeleting)
                // Not the default button (Return): a deletion is always a deliberate click.
                Button("Supprimer", role: .destructive, action: controller.confirm)
                    .buttonStyle(.capsule(.destructive))
                    .disabled(controller.isDeleting)
                    .accessibilityLabel(controller.alsoTrashFolder
                                        ? Text("Supprimer la galerie et mettre le dossier à la corbeille")
                                        : Text("Supprimer la galerie"))
            }
        }
    }
}

/// The box « Mettre aussi le dossier à la corbeille », with the folder's path, file count and size.
private struct FolderTrashBox: View {
    let request: GalleryDeletionRequest
    let check: FolderTrashCheck?
    @Binding var isOn: Bool

    var body: some View {
        let path = abbreviatedPath(check?.folderPath ?? request.folderPath, home: realHomeDirectory())
        let isAllowed = check?.isAllowed == true
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mettre aussi le dossier à la corbeille")
                        .fontWeight(.semibold)
                    Text(verbatim: path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(path)
                    if let contents = check?.contents {
                        Text(verbatim: contents.summary())
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if check == nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Lecture du dossier…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!isAllowed)
            // VoiceOver reads the box as one item: what it does, the folder and its size.
            .accessibilityLabel(Text(verbatim: GalleryDeletionText.checkboxLabel(path: path, contents: check?.contents)))
            .accessibilityHint(check?.block.map { Text(verbatim: $0.message) } ?? Text("Le dossier ira dans la corbeille du Finder, d'où il peut être remis."))

            if let block = check?.block {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: block.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fieldBox()
    }
}

/// The glass banner over the photos after a deletion (« Annuler ») or an undo.
struct GalleryDeletionBannerView: View {
    let banner: GalleryDeletionBanner
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
                    .help("Remettre la galerie (⌘Z)")
                    .accessibilityLabel(Text("Annuler la suppression de « \(banner.galleryName) »"))
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
        .accessibilityLabel("Suppression de galerie")
    }
}

/// The sentences of the deletion window, kept apart so the tests check their French.
enum GalleryDeletionText {
    /// « 52 photos », « 52 photos et 1 vidéo », « 1 vidéo », « Aucune photo ».
    static func contents(photoCount: Int, videoCount: Int, locale: Locale = .current) -> String {
        // `^[…](inflect: true)` only agrees « photo(s) » through an `AttributedString`.
        func inflected(_ value: String.LocalizationValue) -> String {
            String(AttributedString(localized: value, locale: locale).characters)
        }
        let photos = inflected("^[\(photoCount) photo](inflect: true)")
        let videos = inflected("^[\(videoCount) vidéo](inflect: true)")
        switch (photoCount, videoCount) {
        case (0, 0): return String(localized: "Aucune photo", locale: locale)
        case (_, 0): return photos
        case (0, _): return videos
        default: return String(localized: "\(photos) et \(videos)", locale: locale)
        }
    }

    /// What VoiceOver reads for the box.
    static func checkboxLabel(path: String, contents: FolderContents?, locale: Locale = .current) -> String {
        let title = String(localized: "Mettre aussi le dossier à la corbeille", locale: locale)
        guard let contents else { return "\(title). \(path)" }
        return "\(title). \(path). \(contents.summary(locale: locale))"
    }
}
