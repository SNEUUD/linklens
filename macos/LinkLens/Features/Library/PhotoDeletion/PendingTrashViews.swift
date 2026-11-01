import SwiftUI

/// The small orange bin over a photo waiting for its disk to go to the trash (grid, viewer, filmstrip).
struct PendingTrashBadge: View {
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Palette.review.color)
            .frame(width: size, height: size)
            .background(Palette.badge.color, in: Circle())
            .overlay { Circle().strokeBorder(Palette.review.color, lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .help(PendingTrashText.badgeHelp)
            .accessibilityLabel(Text(verbatim: PendingTrashText.accessibilityLabel))
    }
}

/// How much a photo waiting for the trash is dimmed, everywhere it is drawn.
enum PendingTrashStyle {
    static let opacity: Double = 0.5
}

/// Sentences shared by the badge, the cells' VoiceOver labels and the inspector.
enum PendingTrashText {
    static var accessibilityLabel: String { String(localized: "en attente de corbeille") }
    static var badgeHelp: String {
        String(localized: "En attente de corbeille : le fichier sera mis à la corbeille quand son disque sera rebranché, après votre confirmation.")
    }
}

/// The marking window, while the gallery's disk is unplugged: « Mettre 12 photos en attente de corbeille ? ».
/// Nothing is moved: the photos are marked, and the trash is offered again when the disk is back.
struct PendingTrashForm: View {
    @Environment(PhotoDeletionController.self) private var controller
    let request: PhotoDeletionRequest
    let volumeName: String
    let cache: ThumbnailCache

    var body: some View {
        let title = PhotoDeletionText.pendingTitle(count: request.count, kind: request.kind)
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                systemImage: "trash",
                tint: Palette.review,
                soft: Palette.reviewSoft,
                title: Text(verbatim: title),
                subtitle: Text(verbatim: PhotoDeletionText.filesSummary(count: request.count, bytes: request.totalBytes))
            )

            PhotoTrashPreviewStrip(items: request.previews, total: request.count, cache: cache)

            MessageBox(systemImage: "externaldrive.badge.xmark", tint: Palette.review, soft: Palette.reviewSoft) {
                Text(verbatim: PhotoDeletionText.pendingExplanation(volumeName: volumeName))
            }

            if request.kind == .rejected {
                MessageBox(systemImage: "xmark.circle.fill", tint: Palette.reject, soft: Palette.rejectSoft) {
                    Text("Ce sont les photos marquées Rejeter, par vous ou par l'IA. Vérifiez-les d'abord avec le filtre Rejeter (⌘4) : l'IA peut se tromper.")
                }
            }

            MessageBox(systemImage: "arrow.uturn.backward.circle", tint: Palette.accent, soft: Palette.accentSoft) {
                Text("En attendant, ces photos restent visibles, grisées avec une petite corbeille. Vous pouvez annuler (⌘Z) ou les retirer de l'attente (clic droit) à tout moment.")
            }

            if let error = controller.errorMessage {
                MessageBox(systemImage: "xmark.octagon.fill", tint: Palette.reject, soft: Palette.rejectSoft) {
                    Text(verbatim: error)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Annuler", role: .cancel, action: controller.cancel)
                    .buttonStyle(.capsule(.secondary))
                    .keyboardShortcut(.cancelAction)
                // No file is touched: Return may confirm.
                Button("Mettre en attente", action: controller.confirm)
                    .buttonStyle(.capsule(.prominent))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(Text(verbatim: title.replacingOccurrences(of: " ?", with: "")))
            }
        }
    }
}

/// Over the photos once the disk is back: « 26 photos en attente de corbeille », with « Mettre à la
/// corbeille… » (the usual confirmation window, every file checked again) and « Retirer de l'attente ».
/// Only an offer: nothing moves until the user clicks and confirms.
struct PendingTrashBar: View {
    let count: Int
    /// Nil while the trash is not possible now (`trashHelp` says why).
    let onTrash: (() -> Void)?
    let trashHelp: String
    let onUnmark: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.review.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: PhotoDeletionText.pendingCount(count))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("Le disque est rebranché. Rien n'est déplacé sans votre confirmation.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Retirer de l'attente", action: onUnmark)
                .buttonStyle(.capsule(.secondary, size: .small))
                .lineLimit(1)
                .help("Garder ces photos : elles restent dans LinkLens et sur le disque. Vous pourrez annuler (⌘Z).")
                .accessibilityLabel(Text("Retirer les photos de l'attente de corbeille"))
            Button("Mettre à la corbeille…") { onTrash?() }
                .buttonStyle(.capsule(.destructive, size: .small))
                .lineLimit(1)
                .disabled(onTrash == nil)
                .help(trashHelp)
                .accessibilityLabel(Text(verbatim: PhotoDeletionText.trashMenuTitle(count: count)))
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassBackground(in: RoundedRectangle(cornerRadius: Radius.card))
        .padding(.horizontal, GridLayout.padding)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Photos en attente de corbeille"))
    }
}
