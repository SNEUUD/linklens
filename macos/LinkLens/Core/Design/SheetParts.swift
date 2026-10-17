import SwiftUI

// The parts shared by the app's windows (sheets): card import, gallery deletion.

/// Icon in a tinted rounded square, title and one line under it, as at the top of the mockup's windows
/// (card import, gallery deletion).
struct SheetHeader<Accessory: View>: View {
    let systemImage: String
    let tint: AdaptiveColor
    let soft: AdaptiveColor
    let title: Text
    let subtitle: Text
    /// Something at the end of the title line (a spinner while the card is read).
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(tint.color)
                .frame(width: 44, height: 44)
                .background(soft.color, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.system(size: 17, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h1)
                subtitle
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(systemImage: String, tint: AdaptiveColor, soft: AdaptiveColor, title: Text, subtitle: Text) {
        self.init(systemImage: systemImage, tint: tint, soft: soft, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A rounded tinted box with an icon and a message (the green « shield » of the mockup).
struct MessageBox<Content: View>: View {
    let systemImage: String
    /// Nil: the icon takes the text colour.
    let tint: AdaptiveColor?
    let soft: AdaptiveColor
    var isProminent = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: isProminent ? 20 : 15))
                .foregroundStyle(tint.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                .frame(width: isProminent ? 26 : 18)
                .accessibilityHidden(true)
            content
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(isProminent ? 14 : 12)
        .background(soft.color, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The look of the mockup's fields: pale fill, thin line, and an accent halo while typing.
    func fieldBox(isFocused: Bool = false) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Palette.field.color, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line.color, lineWidth: 1))
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.accentSoft.color, lineWidth: 3)
                        .padding(-1.5)
                }
            }
    }
}
