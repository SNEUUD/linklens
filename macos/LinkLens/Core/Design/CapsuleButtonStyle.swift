import SwiftUI

/// The capsule buttons of the mockup: accent-filled for the main action (« Importer 11 fichiers »),
/// a raised white card for the others (« Annuler »).
///
/// A `ButtonStyle` draws every button it is applied to, from its label and whether it is pressed
/// (like a styled `<Button variant="primary">` component in React).
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind {
        case prominent
        case secondary
        /// Red, for an action that removes something (« Supprimer »).
        case destructive
    }

    enum Size {
        /// Welcome screen: 14 pt text, 12 × 22 pt padding.
        case large
        /// Card import window: 13 pt text, 10 × 18 pt padding.
        case regular
        /// « Changer… » inside a field.
        case small
    }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        // A nested view, because only a view can read `isEnabled` from the environment.
        CapsuleButton(configuration: configuration, kind: kind, size: size)
    }

    private struct CapsuleButton: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(kind == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background {
                    switch kind {
                    case .prominent:
                        Capsule().fill(Palette.accent.color)
                    case .destructive:
                        Capsule().fill(Palette.rejectFill.color)
                    case .secondary:
                        Capsule()
                            .fill(Palette.card.color)
                            .overlay(Capsule().strokeBorder(Palette.line.color, lineWidth: 0.5))
                            .shadow(color: .black.opacity(size == .small ? 0 : 0.06), radius: 1, y: 1)
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }

        private var font: Font {
            switch size {
            case .large: .system(size: 14, weight: .semibold)
            case .regular: .system(size: 13, weight: kind == .secondary ? .medium : .semibold)
            case .small: .system(size: 12, weight: .medium)
            }
        }

        private var horizontalPadding: CGFloat {
            switch size {
            case .large: 22
            case .regular: kind == .secondary ? 18 : 20
            case .small: 12
            }
        }

        private var verticalPadding: CGFloat {
            switch size {
            case .large: 12
            case .regular: 10
            case .small: 5
            }
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    /// `.buttonStyle(.capsule(.prominent, size: .large))`, like the built-in `.borderedProminent`.
    static func capsule(_ kind: CapsuleButtonStyle.Kind = .secondary, size: CapsuleButtonStyle.Size = .regular) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: kind, size: size)
    }
}
