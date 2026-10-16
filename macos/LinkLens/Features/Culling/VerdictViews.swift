import SwiftUI

extension CullingVerdict {
    /// The older colours, still used by the viewer's buttons until batch 4. Elsewhere: `tint`.
    var color: Color {
        switch self {
        case .keep: .green
        case .review: .orange
        case .reject: .red
        case .unknown: .gray
        }
    }

    /// Symbol drawn in the colour, so the verdict stays readable without colours.
    var symbolName: String {
        switch self {
        case .keep: "checkmark"
        case .review: "questionmark"
        case .reject: "xmark"
        case .unknown: "minus"
        }
    }
}

/// Verdict as a coloured dot and a word (the word keeps it readable without colours and for VoiceOver).
/// A verdict chosen by the user gets a person symbol, so it never looks like the AI's proposal.
struct VerdictBadge: View {
    let verdict: CullingVerdict?
    var isChosenByUser = false

    var body: some View {
        if let verdict {
            HStack(spacing: 4) {
                Label {
                    Text(verdict.label)
                } icon: {
                    Circle()
                        .fill(verdict.tint)
                        .frame(width: 8, height: 8)
                }
                if isChosenByUser {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Votre choix")
                        .accessibilityLabel("votre choix")
                }
            }
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pas encore triée")
        }
    }
}

/// Verdict drawn over a thumbnail, as in the mockup: the symbol in its colour on a small round badge,
/// so it reads by its shape as well as its colour. A verdict chosen by the user gets a ring.
struct VerdictDisc: View {
    let verdict: CullingVerdict
    var isChosenByUser = false

    var body: some View {
        Image(systemName: verdict.symbolName)
            .font(.system(size: verdict == .reject ? 11 : 12, weight: .heavy))
            .foregroundStyle(verdict.tint)
            .photoBadge(ringColor: isChosenByUser ? verdict.tint : nil)
            .help(isChosenByUser ? "\(verdict.label), votre choix" : verdict.label)
    }
}

/// Star of the best photo of a burst, on the same round badge. Ringed when the user chose it (B).
struct BestOfBurstStar: View {
    let burst: BurstPlacement

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Palette.gold.color)
            .photoBadge(ringColor: burst.isCoverChosenByUser ? Palette.gold.color : nil)
            .help(burst.starDescription)
            .accessibilityLabel(Text(verbatim: burst.starDescription))
    }
}

extension View {
    /// The 24-point round badge of the thumbnails: nearly opaque background, soft shadow, and an
    /// optional ring (the user's own choice).
    func photoBadge(ringColor: Color? = nil) -> some View {
        frame(width: 24, height: 24)
            .background(Palette.badge.color, in: Circle())
            .overlay {
                if let ringColor {
                    Circle().strokeBorder(ringColor, lineWidth: 1.5)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

/// Garder / À revoir / Rejeter / Proposition de l'IA, for context menus and VoiceOver actions.
struct SortingButtons: View {
    /// Adds the key to each title (« Garder (P) »), for menus; VoiceOver actions go without.
    var showsKeys = false
    let action: (SortingCommand) -> Void

    var body: some View {
        // `ForEach` over plain values needs an id for each one (like the `key` prop in a React list).
        ForEach(SortingCommand.all, id: \.self) { command in
            Button(showsKeys ? "\(command.title) (\(command.key))" : command.title) {
                action(command)
            }
        }
    }
}

/// « Choisir comme meilleure de la rafale » and « Revenir à la meilleure selon l'IA » (F4), for context
/// menus and VoiceOver actions. Each one only appears when it would change something.
struct BurstCoverButtons: View {
    let burst: BurstPlacement
    /// Adds the key to the title, for menus; VoiceOver actions go without.
    var showsKeys = false
    let action: (BurstCoverCommand) -> Void

    var body: some View {
        if !(burst.isCover && burst.isCoverChosenByUser) {
            Button(showsKeys ? "Choisir comme meilleure de la rafale (B)" : "Choisir comme meilleure de la rafale") {
                action(.choose)
            }
        }
        if burst.isCoverChosenByUser {
            Button("Revenir à la meilleure selon l'IA") { action(.followAI) }
        }
    }
}
