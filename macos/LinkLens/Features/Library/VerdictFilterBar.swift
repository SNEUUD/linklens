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

    var body: some View {
        HStack(spacing: 12) {
            VerdictFilterCapsule(filter: filter, counts: counts, onSelect: onSelect)
            Spacer(minLength: 0)
            if let thumbnailWidth {
                ThumbnailSizeSlider(width: thumbnailWidth)
            }
        }
        .padding(.horizontal, GridLayout.padding)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
