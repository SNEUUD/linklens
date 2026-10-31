import Foundation

/// One piece of background work shown by the progress pill at the bottom of the photos:
/// « Export « JPEG pour le web » · 8 sur 26 ».
struct Activity: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        /// F2: reading a folder of photos.
        case indexing
        /// F3: sorting by the AI, running or waiting for its turn.
        case culling
        /// F6: export running.
        case export
        /// F6: export over, shown until closed (« Afficher dans le Finder »).
        case exportFinished
        /// F5: search for identical files.
        case duplicates
        /// Inspector details of photos sorted before they were stored (`DetailsBackfiller`).
        case details
        /// Photos of the gallery going to the trash (`PhotoDeletionController`).
        case photoTrash
    }

    var kind: Kind
    /// « Export « JPEG pour le web » », « Tri par l'IA », « Tri en attente ».
    var title: String
    var completed: Int?
    /// Nil while the amount of work is not known yet: the bar then moves on its own.
    var total: Int?
    /// When it started (or ended, for a finished export): the most recent one is shown.
    var date: Date
    /// False for a finished export: it is closed, not cancelled.
    var isCancellable = true
    /// A finished export with failures or cancelled: drawn with a warning symbol.
    var isWarning = false
    /// Tooltip: the failures of an export, for instance.
    var detail: String?

    var id: Kind { kind }

    /// « 8 sur 26 », nil while the total is unknown.
    var progressText: String? {
        guard let completed, let total else { return nil }
        return String(localized: "\(completed) sur \(total)")
    }

    /// 0…1, nil while the total is unknown.
    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    /// Shown and read by VoiceOver: « Export « JPEG pour le web » · 8 sur 26 ».
    var text: String {
        [title, progressText].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - From the controllers' progress

extension Activity {
    static func indexing(_ progress: IndexingProgress, startedAt: Date) -> Activity {
        Activity(kind: .indexing, title: String(localized: "Indexation du dossier"), completed: progress.completed, total: progress.total, date: startedAt)
    }

    /// Running: with its progress (nil until the first photo is read). Waiting: no progress, and the
    /// oldest date, so whatever really runs is shown first.
    static func culling(_ progress: CullingProgress?, isQueued: Bool, startedAt: Date?) -> Activity {
        if isQueued {
            return Activity(kind: .culling, title: String(localized: "Tri en attente"), date: .distantPast)
        }
        return Activity(
            kind: .culling, title: String(localized: "Tri par l'IA"),
            completed: progress?.completed, total: progress?.total, date: startedAt ?? .distantPast
        )
    }

    static func export(_ progress: ExportProgress, startedAt: Date) -> Activity {
        Activity(
            kind: .export, title: String(localized: "Export « \(String(localized: progress.preset.title)) »"),
            completed: progress.completed, total: progress.total, date: startedAt
        )
    }

    static func exportFinished(_ summary: ExportSummary, at date: Date) -> Activity {
        let count = summary.exportedFiles.count
        var title = String(inflecting: "Export terminé : ^[\(count) photo](inflect: true) dans « \(summary.destination.lastPathComponent) »")
        if summary.wasCancelled {
            title = String(inflecting: "Export annulé : ^[\(count) photo](inflect: true) dans « \(summary.destination.lastPathComponent) »")
        }
        if !summary.failures.isEmpty {
            title += " · " + String(localized: "Échecs : \(summary.failures.count)")
        }
        return Activity(
            kind: .exportFinished, title: title, date: date, isCancellable: false,
            isWarning: summary.wasCancelled || !summary.failures.isEmpty,
            detail: summary.failures.isEmpty ? nil : summary.failures.map(\.message).joined(separator: "\n")
        )
    }

    static func duplicates(_ progress: DuplicateScanProgress?, startedAt: Date) -> Activity {
        Activity(
            kind: .duplicates, title: String(localized: "Recherche de doublons"),
            completed: progress?.completedFiles, total: progress?.totalFiles, date: startedAt
        )
    }

    static func photoTrash(_ progress: PhotoTrashProgress) -> Activity {
        Activity(
            kind: .photoTrash, title: String(localized: "Mise à la corbeille"),
            completed: progress.completed, total: progress.total, date: progress.startedAt
        )
    }

    static func details(_ progress: DetailsProgress?, startedAt: Date) -> Activity {
        Activity(
            kind: .details, title: String(localized: "Lecture des détails des photos"),
            completed: progress?.completed, total: progress?.total, date: startedAt
        )
    }
}

/// What the pill shows when several things run at once: the most recent one, and « +1 » for the others.
enum ActivityPill {
    struct Content: Equatable {
        var shown: Activity
        /// Listed in the « +1 » popover, most recent first.
        var others: [Activity]

        /// « +1 », « +2 », nil when nothing else runs.
        var othersBadge: String? {
            others.isEmpty ? nil : "+\(others.count)"
        }
    }

    /// Nil when nothing runs: the pill is hidden. On equal dates, the order of `Activity.Kind` decides,
    /// so the pill never flickers between two activities.
    static func content(for activities: [Activity]) -> Content? {
        let ordered = activities.sorted { first, second in
            if first.date != second.date { return first.date > second.date }
            return priority(first.kind) < priority(second.kind)
        }
        guard let shown = ordered.first else { return nil }
        return Content(shown: shown, others: Array(ordered.dropFirst()))
    }

    private static func priority(_ kind: Activity.Kind) -> Int {
        switch kind {
        case .photoTrash: 0
        case .export: 0
        case .culling: 1
        case .indexing: 2
        case .duplicates: 3
        case .details: 4
        case .exportFinished: 5
        }
    }
}
