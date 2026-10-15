import SwiftUI

extension CullingVerdict {
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
                        .fill(verdict.color)
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

/// Compact verdict drawn over a thumbnail: a coloured disc with a symbol for the AI's proposal,
/// a wider capsule with a person symbol for the user's own choice.
struct VerdictMark: View {
    let verdict: CullingVerdict
    var isChosenByUser = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: verdict.symbolName)
            if isChosenByUser {
                Image(systemName: "person.fill")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white)
        .frame(minWidth: 20, minHeight: 20)
        .padding(.horizontal, isChosenByUser ? 5 : 0)
        .background(verdict.color, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: isChosenByUser ? 1.5 : 1))
        .shadow(color: .black.opacity(0.4), radius: 2)
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

/// Star of the best photo of a burst, readable over any photo.
struct BestOfBurstStar: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.yellow)
            .frame(width: 20, height: 20)
            .background(.black.opacity(0.55), in: Circle())
            .accessibilityLabel("Meilleure photo de la rafale")
    }
}
