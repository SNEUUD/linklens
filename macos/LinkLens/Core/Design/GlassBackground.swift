import SwiftUI

/// How a floating control (progress pill, viewer bar…) gets its background.
enum GlassStyle: Equatable {
    /// Liquid Glass, macOS 26 and later.
    case liquidGlass
    /// Translucent blur, macOS 15.
    case material
    /// Plain window colour, when « Réduire la transparence » is on in System Settings › Accessibility.
    case opaque

    /// The choice, kept pure so it can be tested on any macOS version.
    static func resolve(supportsLiquidGlass: Bool, reduceTransparency: Bool) -> GlassStyle {
        if reduceTransparency { return .opaque }
        return supportsLiquidGlass ? .liquidGlass : .material
    }

    /// True on macOS 26 and later. `#available` checks the macOS version at run time: code inside
    /// may use newer APIs while the app still runs on macOS 15 (like feature detection in a browser).
    static var systemSupportsLiquidGlass: Bool {
        if #available(macOS 26, *) { true } else { false }
    }
}

/// The one glass background of the app. Use it through `.glassBackground(in:)`.
///
/// A `ViewModifier` is a reusable bundle of modifiers with its own state, applied with `.modifier(…)`:
/// close to a React higher-order component wrapping its child.
struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch GlassStyle.resolve(supportsLiquidGlass: GlassStyle.systemSupportsLiquidGlass, reduceTransparency: reduceTransparency) {
        case .liquidGlass:
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        case .material:
            content.background(.regularMaterial, in: shape)
        case .opaque:
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26, a translucent material on macOS 15, an opaque background when the
    /// user reduces transparency. `in` is the shape of the glass, a capsule by default.
    func glassBackground<S: Shape>(in shape: S) -> some View {
        modifier(GlassBackground(shape: shape))
    }

    func glassBackground() -> some View {
        glassBackground(in: Capsule())
    }
}
