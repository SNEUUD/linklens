import Foundation

/// The sentences of the photo deletion, kept apart so the tests check their French (agreements written
/// by hand: « 1 photo mise », « 3 photos mises »).
enum PhotoDeletionText {
    /// Context menu: « Mettre à la corbeille… » (one photo), « Mettre les 3 photos à la corbeille… ».
    static func trashMenuTitle(count: Int) -> String {
        count > 1
            ? String(localized: "Mettre les \(count) photos à la corbeille…")
            : String(localized: "Mettre à la corbeille…")
    }

    /// « Galerie » menu and « Rejeter » filter: « Mettre les 26 photos rejetées à la corbeille… ».
    static func rejectedMenuTitle(count: Int) -> String {
        switch count {
        case 0: String(localized: "Mettre les photos rejetées à la corbeille…")
        case 1: String(localized: "Mettre la photo rejetée à la corbeille…")
        default: String(localized: "Mettre les \(count) photos rejetées à la corbeille…")
        }
    }

    /// The window's title: « Mettre 12 photos à la corbeille ? », « Mettre les 26 photos rejetées à la corbeille ? ».
    static func title(count: Int, kind: PhotoDeletionRequest.Kind) -> String {
        switch (kind, count) {
        case (.selection, 1): String(localized: "Mettre 1 photo à la corbeille ?")
        case (.selection, _): String(localized: "Mettre \(count) photos à la corbeille ?")
        case (.rejected, 1): String(localized: "Mettre la photo rejetée à la corbeille ?")
        case (.rejected, _): String(localized: "Mettre les \(count) photos rejetées à la corbeille ?")
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
