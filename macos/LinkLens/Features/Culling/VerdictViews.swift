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
struct VerdictBadge: View {
    let verdict: CullingVerdict?

    var body: some View {
        if let verdict {
            Label {
                Text(verdict.label)
            } icon: {
                Circle()
                    .fill(verdict.color)
                    .frame(width: 8, height: 8)
            }
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pas encore triée")
        }
    }
}

/// Compact verdict drawn over a thumbnail: a coloured disc with a symbol.
struct VerdictMark: View {
    let verdict: CullingVerdict

    var body: some View {
        Image(systemName: verdict.symbolName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(verdict.color, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 2)
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
