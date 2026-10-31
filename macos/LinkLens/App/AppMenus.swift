import SwiftUI

/// What the « Galerie » menu can do for the gallery shown in the front window. A nil action is a
/// disabled item; its `…Help` says why (F9: disk unplugged).
///
/// `Sendable`: the closures run on the main thread (`@MainActor`), so the value can be handed to
/// the menu bar safely.
struct GalleryMenuActions: Sendable {
    var cullTitle: String
    var cull: (@MainActor () -> Void)?
    var cullHelp: String
    var export: (@MainActor () -> Void)?
    var exportHelp: String
    var reveal: (@MainActor () -> Void)?
    var revealHelp: String
    /// « Supprimer la galerie… » (⌘⌫): opens the confirmation window. Nil while it cannot be deleted.
    var delete: (@MainActor () -> Void)? = nil
    var deleteHelp = ""
    /// « Revoir les photos à revoir… » or « Reprendre la revue… » (⌘R). Nil when there is nothing to review
    /// or the review is already shown.
    var reviewTitle = String(localized: "Revoir les photos à revoir…")
    var review: (@MainActor () -> Void)? = nil
    /// « Supprimer les photos sélectionnées… »: the confirmation window for the selection. Nil while
    /// nothing is selected or the photos cannot be deleted (`trashHelp` says why).
    var trashSelection: (@MainActor () -> Void)? = nil
    /// « Mettre les 26 photos rejetées à la corbeille… ». Nil when no photo is « Rejeter ».
    var trashRejectedTitle = PhotoDeletionText.rejectedMenuTitle(count: 0)
    var trashRejected: (@MainActor () -> Void)? = nil
    var trashHelp = ""
}

/// Which deletion ⌘⌫ asks for: the selected photos while the grid or the table has the keyboard,
/// otherwise the gallery (as before, e.g. after a click in the sidebar). The other item keeps its
/// place in the menu, without the shortcut.
enum DeleteShortcutTarget: Equatable {
    case photos, gallery

    init(photosHaveFocus: Bool) {
        self = photosHaveFocus ? .photos : .gallery
    }

    static let shortcut = KeyboardShortcut(.delete, modifiers: .command)

    /// The shortcut of each menu item: on one of them only.
    func shortcut(for item: DeleteShortcutTarget) -> KeyboardShortcut? {
        item == self ? Self.shortcut : nil
    }
}

/// What the « Présentation » menu can do for the gallery in the front window: the verdict filters
/// (⌘1 to ⌘4, with their counts) and the thumbnail size (⌘+ / ⌘−, grid only).
struct GalleryPresentationActions: Sendable {
    var filter: VerdictFilter
    var counts: VerdictFilterCounts
    var select: @MainActor (VerdictFilter) -> Void
    var canResizeThumbnails: Bool
}

extension FocusedValues {
    // A focused value is published by the view of the front window and read by the menu bar,
    // which lives outside the window (like a React context shared with a portal).
    /// Set by `GalleryDetailView` while a gallery is shown.
    @Entry var galleryMenuActions: GalleryMenuActions?
    /// Set by `GalleryDetailView` while a gallery is shown.
    @Entry var galleryPresentation: GalleryPresentationActions?
    /// Set by `ContentView` once there is at least one gallery.
    @Entry var showDuplicates: MenuAction?
    /// True while the grid or the table of photos has the keyboard (`focusedValue`, not
    /// `focusedSceneValue`: only published by the focused view). Decides what ⌘⌫ deletes.
    @Entry var photosHaveFocus: Bool?
}

/// One menu action, wrapped in a struct: a bare closure as a focused value makes SwiftUI refresh the
/// menu on every update, since two closures cannot be compared.
struct MenuAction: Sendable {
    let perform: @MainActor () -> Void
}

/// The « Galerie » menu of the menu bar: Trier à nouveau, Exporter…, Afficher dans le Finder, Revoir les
/// photos à revoir…, Doublons…, Supprimer la galerie….
struct GalleryMenuCommands: View {
    @FocusedValue(\.galleryMenuActions) private var actions
    @FocusedValue(\.showDuplicates) private var showDuplicates
    @FocusedValue(\.photosHaveFocus) private var photosHaveFocus

    var body: some View {
        Button(actions?.cullTitle ?? String(localized: "Trier à nouveau")) { actions?.cull?() }
            .disabled(actions?.cull == nil)
            .help(actions?.cullHelp ?? "")
        Button("Exporter…") { actions?.export?() }
            .keyboardShortcut("e")
            .disabled(actions?.export == nil)
            .help(actions?.exportHelp ?? "")
        Button("Afficher dans le Finder") { actions?.reveal?() }
            .disabled(actions?.reveal == nil)
            .help(actions?.revealHelp ?? "")
        Divider()
        // ⌘R: free in the system's menus (no « Reload » in a Mac app without a web view).
        Button(actions?.reviewTitle ?? String(localized: "Revoir les photos à revoir…")) { actions?.review?() }
            .keyboardShortcut("r")
            .disabled(actions?.review == nil)
            .help("Passer en revue les photos « À revoir », une rafale à la fois")
        Divider()
        Button("Doublons…") { showDuplicates?.perform() }
            .disabled(showDuplicates == nil)
            .help("Rechercher les fichiers identiques dans toutes vos galeries")
        Divider()
        // ⌘⌫ (`.delete` is the ⌫ key) goes to the photos when they have the keyboard, else to the gallery.
        // Always through a confirmation window: nothing is deleted at once.
        let target = DeleteShortcutTarget(photosHaveFocus: photosHaveFocus == true)
        Button("Supprimer les photos sélectionnées…") { actions?.trashSelection?() }
            .keyboardShortcut(target.shortcut(for: .photos))
            .disabled(actions?.trashSelection == nil)
            .help(actions?.trashHelp ?? "")
        Button(actions?.trashRejectedTitle ?? PhotoDeletionText.rejectedMenuTitle(count: 0)) { actions?.trashRejected?() }
            .disabled(actions?.trashRejected == nil)
            .help("Les photos marquées Rejeter, par vous ou par l'IA, vont dans la corbeille du Finder. Vous pourrez annuler.")
        Button("Supprimer la galerie…") { actions?.delete?() }
            .keyboardShortcut(target.shortcut(for: .gallery))
            .disabled(actions?.delete == nil)
            .help(actions?.deleteHelp ?? "")
    }
}

/// « Carte SD… » and « Dossier… »: the two ways to add a gallery. Used by the toolbar menu,
/// the sidebar and the File menu, so they always behave the same.
struct ImportMenuItems: View {
    /// ⇧⌘I and ⌘O are shown (and work) in the File menu and the toolbar menu only.
    var showsShortcuts = true
    var cardTitle: LocalizedStringKey = "Carte SD…"
    var folderTitle: LocalizedStringKey = "Dossier…"
    @Environment(ImportController.self) private var importController
    @Environment(CardImportController.self) private var cardImportController

    var body: some View {
        Button(cardTitle, systemImage: "sdcard", action: cardImportController.chooseCard)
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut("i", modifiers: [.command, .shift]) : nil)
            .disabled(cardImportController.isSheetPresented)
            .help("Copier les photos et vidéos d'une carte SD dans une nouvelle galerie")
        Button(folderTitle, systemImage: "folder", action: importController.chooseFolder)
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut("o") : nil)
            .disabled(importController.isIndexing)
            .help("Indexer un dossier de photos sans le copier")
    }
}

/// « Importer ▾ » in the toolbar.
struct ImportToolbarMenu: View {
    var body: some View {
        Menu {
            ImportMenuItems()
        } label: {
            Label("Importer", systemImage: "plus")
        }
        .labelStyle(.titleAndIcon)
        .help("Importer une carte SD ou ajouter un dossier de photos")
    }
}

/// The top of the « Présentation » menu: « Toutes · 52 » ⌘1 … « Rejeter · 26 » ⌘4, then the
/// thumbnail size. A tick shows the current filter.
struct PresentationMenuCommands: View {
    @FocusedValue(\.galleryPresentation) private var actions
    // The same stored value as the slider of the gallery: both always agree.
    @AppStorage(ThumbnailSize.storageKey) private var thumbnailWidth = ThumbnailSize.standard
    /// The same stored value as the inspector button of the toolbar.
    @AppStorage("isInspectorShown") private var isInspectorShown = true

    var body: some View {
        ForEach(VerdictFilter.allCases, id: \.self) { filter in
            // A `Toggle` in a menu is drawn as an item with a tick while on.
            Toggle(isOn: Binding(
                get: { actions?.filter == filter },
                // Chosen again while already on: shows the photos sorted since (see `VerdictFilter`).
                set: { _ in actions?.select(filter) }
            )) {
                Text(verbatim: actions?.counts.title(of: filter) ?? filter.title)
            }
            .keyboardShortcut(KeyEquivalent(filter.shortcutDigit), modifiers: .command)
            .disabled(actions == nil)
        }
        Divider()
        Button("Agrandir les vignettes") { thumbnailWidth = ThumbnailSize.zoomed(thumbnailWidth, steps: 1) }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(actions?.canResizeThumbnails != true || thumbnailWidth >= ThumbnailSize.range.upperBound)
        Button("Réduire les vignettes") { thumbnailWidth = ThumbnailSize.zoomed(thumbnailWidth, steps: -1) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(actions?.canResizeThumbnails != true || thumbnailWidth <= ThumbnailSize.range.lowerBound)
        Divider()
        Button(isInspectorShown ? "Masquer l'inspecteur" : "Afficher l'inspecteur") { isInspectorShown.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions == nil)
        Divider()
    }
}
