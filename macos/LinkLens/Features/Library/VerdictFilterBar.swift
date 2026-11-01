import SwiftUI

/// The row under the toolbar, as in the mockup: the four verdict filters in a glass capsule on the
/// left, the thumbnail size slider on the right (grid only).
struct VerdictFilterBar: View {
    let filter: VerdictFilter
    let counts: VerdictFilterCounts
    /// Called on a click, also on the filter already chosen (it then shows the photos sorted since).
    let onSelect: (VerdictFilter) -> Void
    /// Nil hides the slider (table, viewer).
    var thumbnailWidth: Binding<Double>?
    /// « Revoir les 14 » or « Reprendre la revue (reste 9) »; nil when nothing is « À revoir ».
    var review: ReviewEntryPoint? = nil
    var onReview: () -> Void = {}
    /// « Mettre les 26 photos rejetées à la corbeille… », shown under the « Rejeter » filter only.
    var trashRejected: TrashRejectedAction? = nil

    var body: some View {
        HStack(spacing: 12) {
            // `layoutPriority(1)`: when the row is narrow (inspector open), the filters get their full
            // width before the spacer, so their labels stay on one line (`lineLimit(1)` below).
            // No `fixedSize()` here: it triggered an AppKit layout loop (crash during the renders).
            VerdictFilterCapsule(filter: filter, counts: counts, onSelect: onSelect)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if filter == .reject, let trashRejected, trashRejected.count > 0 {
                ViewThatFits(in: .horizontal) {
                    trashTrailing(trashRejected, isCompact: false, showsSlider: true)
                    trashTrailing(trashRejected, isCompact: false, showsSlider: false)
                    trashTrailing(trashRejected, isCompact: true, showsSlider: false)
                }
            } else if let review {
                // `ViewThatFits` shows the first version that fits the width left by the filters (like a
                // series of CSS container queries): the review button shrinks first, then the slider
                // gives way to it (⌘+ / ⌘− still resize the thumbnails).
                ViewThatFits(in: .horizontal) {
                    trailing(review, style: .full, showsSlider: true)
                    trailing(review, style: .short, showsSlider: true)
                    trailing(review, style: .short, showsSlider: false)
                    trailing(review, style: .compact, showsSlider: false)
                }
            } else if let thumbnailWidth {
                ThumbnailSizeSlider(width: thumbnailWidth)
            }
        }
        .padding(.horizontal, GridLayout.padding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func trashTrailing(_ action: TrashRejectedAction, isCompact: Bool, showsSlider: Bool) -> some View {
        HStack(spacing: 12) {
            Button(role: .destructive, action: action.perform) {
                if isCompact {
                    Label(action.marksPending ? String(localized: "En attente (\(action.count))…") : String(localized: "Corbeille (\(action.count))…"), systemImage: "trash")
                } else {
                    Label(action.title, systemImage: "trash")
                }
            }
            .buttonStyle(.capsule(.destructive, size: .small))
            .lineLimit(1)
            .help(action.marksPending
                ? "Le disque est débranché : les photos de ce filtre seront mises en attente de corbeille, sans toucher aux fichiers. Vous pourrez annuler."
                : "Les photos de ce filtre vont dans la corbeille du Finder, après confirmation. Vous pourrez annuler.")
            .accessibilityLabel(Text(verbatim: action.title))
            if showsSlider, let thumbnailWidth {
                ThumbnailSizeSlider(width: thumbnailWidth)
            }
        }
    }

    private func trailing(_ review: ReviewEntryPoint, style: ReviewEntryButton.Style, showsSlider: Bool) -> some View {
        HStack(spacing: 12) {
            ReviewEntryButton(entryPoint: review, style: style, action: onReview)
            if showsSlider, let thumbnailWidth {
                ThumbnailSizeSlider(width: thumbnailWidth)
            }
        }
    }
}

/// « Toutes · 52 | ✓ Garder · 12 | ? À revoir · 14 | ✕ Rejeter · 26 »: a segmented control drawn
/// as in the mockup, the chosen filter raised on a chip.
private struct VerdictFilterCapsule: View {
    let filter: VerdictFilter
    let counts: VerdictFilterCounts
    let onSelect: (VerdictFilter) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VerdictFilter.allCases, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .glassBackground()
        // `.contain`: VoiceOver sees one group named « Filtrer par tri » holding four buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filtrer par tri")
    }

    private func segment(_ option: VerdictFilter) -> some View {
        let isSelected = option == filter
        return Button {
            onSelect(option)
        } label: {
            HStack(spacing: 6) {
                if let verdict = option.verdict {
                    Image(systemName: verdict.symbolName)
                        .font(.system(size: verdict == .reject ? 10 : 11, weight: .heavy))
                        .foregroundStyle(verdict.tint)
                }
                Text(verbatim: counts.title(of: option))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Palette.chip.color)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(option.title) (⌘\(String(option.shortcutDigit)))")
        .accessibilityLabel(Text(verbatim: counts.accessibilityLabel(of: option)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small square, slider, big square: the size of the thumbnails (also ⌘+ / ⌘−).
private struct ThumbnailSizeSlider: View {
    @Binding var width: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square")
                .font(.system(size: 10))
                .accessibilityHidden(true)
            // No `step:` (it draws tick marks the mockup does not have): the value snaps here instead.
            Slider(value: Binding(get: { width }, set: { width = ThumbnailSize.zoomed($0, steps: 0) }), in: ThumbnailSize.range)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityLabel("Taille des vignettes")
            Image(systemName: "square")
                .font(.system(size: 15))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .help("Taille des vignettes (⌘+ / ⌘−)")
    }
}
