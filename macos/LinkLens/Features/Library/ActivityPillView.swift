import SwiftUI

/// The one progress indicator of the gallery, as in the mockup: a glass pill at the bottom centre of
/// the photos. « Export « JPEG pour le web » · 8 sur 26 », a bar, « Annuler ».
///
/// It gathers the indexing (F2), the AI sorting (F3), the export (F6, then its result) and the
/// duplicate search (F5). When several run, the most recent one is shown with « +1 »: a click on it
/// lists the others, each with its own « Annuler ».
struct ActivityPillView: View {
    let content: ActivityPill.Content
    /// Cancels (or closes, for a finished export) one activity.
    let onCancel: (Activity.Kind) -> Void
    /// « Afficher dans le Finder » after an export.
    let onRevealExport: () -> Void
    @State private var isShowingOthers = false

    var body: some View {
        HStack(spacing: 12) {
            ActivityRow(activity: content.shown, onCancel: onCancel, onRevealExport: onRevealExport)
            if let badge = content.othersBadge {
                Button(badge) { isShowingOthers.toggle() }
                    .buttonStyle(PillButtonStyle())
                    .monospacedDigit()
                    .help("Autres tâches en cours")
                    .accessibilityLabel(Text("^[\(content.others.count) autre tâche](inflect: true) en cours"))
                    // A popover is a bubble attached to a view (like a Popper.js tooltip that holds content).
                    .popover(isPresented: $isShowingOthers, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(content.others) { activity in
                                ActivityRow(activity: activity, onCancel: onCancel, onRevealExport: onRevealExport)
                            }
                        }
                        .padding(14)
                    }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Progression")
    }
}

/// Symbol, text, bar and button of one activity.
private struct ActivityRow: View {
    let activity: Activity
    let onCancel: (Activity.Kind) -> Void
    let onRevealExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(activity.isWarning ? Palette.review.color : Color.accentColor)
                Text(verbatim: activity.text)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .lineLimit(1)
                if activity.kind != .exportFinished {
                    ProgressBar(fraction: activity.fraction)
                }
            }
            .help(activity.detail ?? activity.text)
            // VoiceOver reads the text and the progress as one element, then the buttons.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: activity.title))
            .accessibilityValue(Text(verbatim: activity.progressText ?? String(localized: "en cours")))
            .accessibilityAddTraits(.updatesFrequently)

            if activity.kind == .exportFinished {
                Button("Afficher dans le Finder", action: onRevealExport)
                    .buttonStyle(PillButtonStyle())
                Button {
                    onCancel(activity.kind)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(PillButtonStyle())
                .help("Fermer")
                .accessibilityLabel("Fermer")
            } else {
                Button("Annuler") { onCancel(activity.kind) }
                    .buttonStyle(PillButtonStyle())
                    .help(cancelHelp)
            }
        }
    }

    private var symbolName: String {
        switch activity.kind {
        case .indexing: "folder"
        case .culling: "wand.and.stars"
        case .export: "square.and.arrow.up"
        case .exportFinished: activity.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .duplicates: "square.on.square"
        }
    }

    private var cancelHelp: String {
        switch activity.kind {
        case .indexing: String(localized: "Arrêter l'indexation. Les fichiers ne sont pas touchés.")
        case .culling: String(localized: "Arrêter le tri. Les verdicts précédents sont gardés.")
        case .export: String(localized: "Arrêter l'export. Les photos déjà exportées sont gardées.")
        case .exportFinished, .duplicates: String(localized: "Arrêter")
        }
    }
}

/// 120 × 5 points, as in the mockup. Without a fraction (work not counted yet), a short segment slides.
private struct ProgressBar: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 120, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 120 * fraction)
                }
                .animation(.easeOut(duration: 0.2), value: fraction)
        } else {
            // The system's spinning indicator, small, when nothing can be counted yet.
            ProgressView()
                .controlSize(.small)
                .frame(width: 120, height: 5)
        }
    }
}

/// « Annuler », « +1 »: small grey capsule buttons, as in the mockup.
private struct PillButtonStyle: ButtonStyle {
    // A `ButtonStyle` draws every button that uses it (like a styled-components wrapper for <button>).
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
    }
}
