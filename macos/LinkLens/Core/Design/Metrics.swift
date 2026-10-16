import CoreGraphics

/// Corner radii of the approved mockup, in points. A caseless `enum` is only a namespace for
/// constants (like `export const Radius = { … } as const` in TypeScript): it cannot be created.
enum Radius {
    /// Keyboard key caps, small badges.
    static let small: CGFloat = 6
    /// Gallery cover in the sidebar.
    static let cover: CGFloat = 9
    /// Photo thumbnails in the grid.
    static let thumbnail: CGFloat = 10
    /// Sidebar rows, cards, the detected card.
    static let card: CGFloat = 12
    /// Floating panels (sidebar, inspector).
    static let panel: CGFloat = 18
}

/// Spacing scale of the mockup, in points.
enum Spacing {
    static let xxSmall: CGFloat = 2
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let regular: CGFloat = 10
    static let large: CGFloat = 14
    /// Between sidebar sections.
    static let section: CGFloat = 20
}

/// Fixed sizes of the sidebar rows.
enum SidebarMetrics {
    static let coverSize: CGFloat = 42
    static let verdictBarHeight: CGFloat = 4
}
