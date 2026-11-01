import Foundation

/// The sentences of the photo deletion, kept apart so the tests check their French (agreements written
/// by hand: « 1 photo mise », « 3 photos mises »).
enum PhotoDeletionText {
    /// Context menu: « Mettre à la corbeille… » (one photo), « Mettre les 3 photos à la corbeille… ».
    /// `pending`: the disk is unplugged, the photos will only be marked (« Mettre en attente de corbeille… »).
    static func trashMenuTitle(count: Int, pending: Bool = false) -> String {
        if pending {
            return count > 1
                ? String(localized: "Mettre les \(count) photos en attente de corbeille…")
                : String(localized: "Mettre en attente de corbeille…")
        }
        return count > 1
            ? String(localized: "Mettre les \(count) photos à la corbeille…")
            : String(localized: "Mettre à la corbeille…")
    }

    /// « Galerie » menu and « Rejeter » filter: « Mettre les 26 photos rejetées à la corbeille… ».
    static func rejectedMenuTitle(count: Int, pending: Bool = false) -> String {
        if pending {
            return switch count {
            case 0: String(localized: "Mettre les photos rejetées en attente de corbeille…")
            case 1: String(localized: "Mettre la photo rejetée en attente de corbeille…")
            default: String(localized: "Mettre les \(count) photos rejetées en attente de corbeille…")
            }
        }
        return switch count {
        case 0: String(localized: "Mettre les photos rejetées à la corbeille…")
        case 1: String(localized: "Mettre la photo rejetée à la corbeille…")
        default: String(localized: "Mettre les \(count) photos rejetées à la corbeille…")
        }
    }

    // MARK: - Pending trash (disk unplugged)

    /// The marking window's title: « Mettre 12 photos en attente de corbeille ? ».
    static func pendingTitle(count: Int, kind: PhotoDeletionRequest.Kind) -> String {
        switch (kind, count) {
        case (.rejected, 1): String(localized: "Mettre la photo rejetée en attente de corbeille ?")
        case (.rejected, _): String(localized: "Mettre les \(count) photos rejetées en attente de corbeille ?")
        case (_, 1): String(localized: "Mettre 1 photo en attente de corbeille ?")
        case (_, _): String(localized: "Mettre \(count) photos en attente de corbeille ?")
        }
    }

    /// The marking window: what happens, and when.
    static func pendingExplanation(volumeName: String) -> String {
        String(localized: "Le disque « \(volumeName) » n'est pas branché : aucun fichier n'est touché maintenant. Les fichiers seront mis à la corbeille quand le disque « \(volumeName) » sera rebranché, après votre confirmation.")
    }

    /// Banner, sidebar and badges: « 26 photos en attente de corbeille ».
    static func pendingCount(_ count: Int) -> String {
        count > 1
            ? String(localized: "\(count) photos en attente de corbeille")
            : String(localized: "1 photo en attente de corbeille")
    }

    /// The sidebar, where room is short: « 26 en attente de corbeille ».
    static func pendingShort(_ count: Int) -> String {
        String(localized: "\(count) en attente de corbeille")
    }

    /// The Edit menu: « Annuler Mise en attente de corbeille ».
    static func undoActionName(markedPending count: Int) -> String {
        count > 1
            ? String(localized: "Mise en attente de corbeille de \(count) photos")
            : String(localized: "Mise en attente de corbeille d'une photo")
    }

    static func undoActionName(unmarkedPending count: Int) -> String {
        count > 1
            ? String(localized: "Retrait de l'attente de \(count) photos")
            : String(localized: "Retrait de l'attente d'une photo")
    }

    /// Context menu: « Retirer de l'attente de corbeille », « Retirer les 3 photos de l'attente de corbeille ».
    static func unmarkMenuTitle(count: Int) -> String {
        count > 1
            ? String(localized: "Retirer les \(count) photos de l'attente de corbeille")
            : String(localized: "Retirer de l'attente de corbeille")
    }

    /// The window's title: « Mettre 12 photos à la corbeille ? », « Mettre les 26 photos rejetées à la corbeille ? ».
    static func title(count: Int, kind: PhotoDeletionRequest.Kind) -> String {
        switch (kind, count) {
        case (.selection, 1): String(localized: "Mettre 1 photo à la corbeille ?")
        case (.selection, _): String(localized: "Mettre \(count) photos à la corbeille ?")
        case (.rejected, 1): String(localized: "Mettre la photo rejetée à la corbeille ?")
        case (.rejected, _): String(localized: "Mettre les \(count) photos rejetées à la corbeille ?")
        case (.pending, 1): String(localized: "Mettre la photo en attente à la corbeille ?")
        case (.pending, _): String(localized: "Mettre les \(count) photos en attente à la corbeille ?")
        }
    }

    /// « 12 fichiers · 296 Mo », « 1 fichier · 24,1 Mo ». The locale is a parameter for the tests.
    static func filesSummary(count: Int, bytes: Int64, locale: Locale = .current) -> String {
        let files = count > 1 ? String(localized: "\(count) fichiers", locale: locale) : String(localized: "1 fichier", locale: locale)
        return "\(files) · \(bytes.formatted(.byteCount(style: .file).locale(locale)))"
    }

    /// The inspector, several photos selected: « 12 photos sélectionnées ».
    static func selectedTitle(count: Int) -> String {
        count > 1 ? String(localized: "\(count) photos sélectionnées") : String(localized: "1 photo sélectionnée")
    }

    static func trashedTitle(count: Int) -> String {
        count > 1 ? String(localized: "\(count) photos mises à la corbeille") : String(localized: "1 photo mise à la corbeille")
    }

    static func removedTitle(count: Int) -> String {
        count > 1 ? String(localized: "\(count) photos retirées de LinkLens") : String(localized: "1 photo retirée de LinkLens")
    }

    static func restoredTitle(count: Int) -> String {
        count > 1 ? String(localized: "\(count) photos remises en place") : String(localized: "1 photo remise en place")
    }

    /// « 3 fichiers sont restés à leur place. »
    static func keptInPlace(_ count: Int) -> String {
        count > 1
            ? String(localized: "\(count) fichiers sont restés à leur place.")
            : String(localized: "1 fichier est resté à sa place.")
    }

    /// The Edit menu: « Annuler Mise à la corbeille de 12 photos ».
    static func undoActionName(trashed count: Int) -> String {
        count > 1 ? String(localized: "Mise à la corbeille de \(count) photos") : String(localized: "Mise à la corbeille d'une photo")
    }

    static func undoActionName(removed count: Int) -> String {
        count > 1 ? String(localized: "Retrait de \(count) photos") : String(localized: "Retrait d'une photo")
    }

    /// After « Annuler », what could not come back, nil when everything did.
    static func restoreProblem(_ skipped: [SkippedFile]) -> String? {
        guard let first = skipped.first else { return nil }
        let name = (first.relativePath as NSString).lastPathComponent
        if skipped.count == 1 {
            return String(localized: "« \(name) » n'a pas pu revenir : \(first.reason.message) Il reste dans la corbeille du Finder si vous ne l'avez pas vidée.")
        }
        return String(localized: "\(skipped.count) fichiers n'ont pas pu revenir (par exemple « \(name) » : \(first.reason.message)). Ils restent dans la corbeille du Finder si vous ne l'avez pas vidée.")
    }

    /// The report's title.
    static func reportTitle(_ report: PhotoDeletionReport) -> String {
        if report.trashWasRefused, report.trashedCount == 0 {
            return String(localized: "La corbeille a refusé ces fichiers")
        }
        if report.skipped.isEmpty {
            return String(localized: "Mise à la corbeille interrompue")
        }
        return keptInPlace(report.skipped.count).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
