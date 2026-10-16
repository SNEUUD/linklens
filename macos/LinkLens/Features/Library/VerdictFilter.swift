import Foundation

/// The four filters above the photos: « Toutes · 52 », « Garder · 12 », « À revoir · 14 », « Rejeter · 26 ».
///
/// Rules, kept simple so they can be explained:
/// - « Toutes » shows the bursts stacked (F4). Another filter shows each matching photo on its own,
///   bursts unfolded (`BurstStacks.entries(for:expanded:filter:retaining:)`).
/// - A photo sorted out of the filter (P / U / X under « À revoir ») stays in place, dimmed, until the
///   filter changes or is chosen again: the grid never moves under the cursor while sorting.
/// - The filter is remembered per gallery (`storageKey`).
///
/// A `String` raw value lets the choice be saved in the user defaults.
enum VerdictFilter: String, CaseIterable, Sendable {
    case all, keep, review, reject

    /// The verdict shown by this filter, nil for « Toutes ».
    var verdict: CullingVerdict? {
        switch self {
        case .all: nil
        case .keep: .keep
        case .review: .review
        case .reject: .reject
        }
    }

    /// Photos not sorted yet, or with a verdict from a newer version, only appear under « Toutes ».
    func matches(_ verdict: CullingVerdict?) -> Bool {
        guard let wanted = self.verdict else { return true }
        return verdict == wanted
    }

    var title: String {
        switch self {
        case .all: String(localized: "Toutes")
        case .keep, .review, .reject: verdict?.label ?? ""
        }
    }

    /// ⌘1 to ⌘4, in the « Présentation » menu.
    var shortcutDigit: Character {
        switch self {
        case .all: "1"
        case .keep: "2"
        case .review: "3"
        case .reject: "4"
        }
    }

    /// The user defaults key holding the filter of one gallery.
    static func storageKey(galleryId: UUID) -> String {
        "verdictFilter.\(galleryId.uuidString)"
    }
}

/// The number shown on each filter. Manual choices count (`Photo.verdict`).
struct VerdictFilterCounts: Equatable, Sendable {
    var all = 0
    var keep = 0
    var review = 0
    var reject = 0

    init(all: Int = 0, keep: Int = 0, review: Int = 0, reject: Int = 0) {
        self.all = all
        self.keep = keep
        self.review = review
        self.reject = reject
    }

    init(_ verdicts: [CullingVerdict?]) {
        all = verdicts.count
        for verdict in verdicts {
            switch verdict {
            case .keep: keep += 1
            case .review: review += 1
            case .reject: reject += 1
            case .unknown, nil: break
            }
        }
    }

    func count(of filter: VerdictFilter) -> Int {
        switch filter {
        case .all: all
        case .keep: keep
        case .review: review
        case .reject: reject
        }
    }

    /// « Toutes · 52 »: what the filter shows on screen.
    func title(of filter: VerdictFilter) -> String {
        "\(filter.title) · \(count(of: filter))"
    }

    /// Read by VoiceOver: « À revoir, 14 photos ».
    func accessibilityLabel(of filter: VerdictFilter) -> String {
        let count = count(of: filter)
        return String(inflecting: "\(filter.title), ^[\(count) photo](inflect: true)")
    }
}
