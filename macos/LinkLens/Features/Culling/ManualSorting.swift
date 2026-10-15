import Foundation
import OSLog
import SwiftData
import SwiftUI

/// What a sorting key, menu item or button asks for.
// An `enum` case can carry a value (`choose(.keep)`): like a TypeScript discriminated union
// `{ kind: "choose", verdict: "keep" } | { kind: "followAI" }`.
enum SortingCommand: Hashable, Sendable {
    /// The user's own verdict: Garder, À revoir or Rejeter.
    case choose(CullingVerdict)
    /// Forgets the user's choice: the AI's proposal applies again.
    case followAI

    /// Every command, in the order of the menus and buttons.
    static let all: [SortingCommand] = [.choose(.keep), .choose(.review), .choose(.reject), .followAI]

    /// Keys read by the grid, the table and the viewer (both cases: Caps Lock or Shift still work).
    static let keyCharacters = CharacterSet(charactersIn: "pPuUxXaA")

    /// P = Garder (pick), U = À revoir, X = Rejeter, as in Lightroom; A = back to the AI's proposal.
    /// Nil for any other key, or with ⌘, ⌥ or ⌃ held: those belong to the menus.
    init?(characters: String, modifiers: EventModifiers) {
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        switch characters.lowercased() {
        case "p": self = .choose(.keep)
        case "u": self = .choose(.review)
        case "x": self = .choose(.reject)
        case "a": self = .followAI
        default: return nil
        }
    }

    init?(_ press: KeyPress) {
        self.init(characters: press.characters, modifiers: press.modifiers)
    }

    /// Value stored in `Photo.userVerdictRaw`.
    var userVerdictRaw: String? {
        switch self {
        case .choose(let verdict): verdict.rawValue
        case .followAI: nil
        }
    }

    var key: String {
        switch self {
        case .choose(.keep): "P"
        case .choose(.review): "U"
        case .choose(.reject): "X"
        case .choose(.unknown): ""
        case .followAI: "A"
        }
    }

    /// Menu, button and VoiceOver action title.
    var title: String {
        switch self {
        case .choose(let verdict): verdict.label
        case .followAI: String(localized: "Proposition de l'IA")
        }
    }

    /// Shown in the Edit menu: « Annuler Garder », « Rétablir Proposition de l'IA ».
    var undoActionName: String { title }
}

/// Manual sorting: the user's verdict, stored apart from the AI's proposal, with undo and redo.
///
/// One instance per gallery view, shared by the grid, the table and the viewer like `GalleryBrowser`:
/// key handlers kept from an older render still reach the current context and selection.
@MainActor
final class ManualSorter {
    private nonisolated static let logger = Logger(subsystem: "fr.chriscrepin.linklens", category: "sorting")

    /// The main context of the window (the one `@Query` reads), set by the gallery view.
    var context: ModelContext?
    /// The window's undo manager: ⌘Z / ⇧⌘Z and the Edit menu use it.
    // `weak`: the window owns its undo manager; this reference does not keep it alive
    // (like a `WeakRef` in JavaScript, it becomes nil when the window goes away).
    weak var undoManager: UndoManager?
    private weak var browser: GalleryBrowser?

    init(browser: GalleryBrowser?, context: ModelContext? = nil, undoManager: UndoManager? = nil) {
        self.browser = browser
        self.context = context
        self.undoManager = undoManager
    }

    /// A key: sorts the selected photo (the cover of a collapsed burst), then selects the next one
    /// when `advance` is true. Returns false when nothing is selected.
    @discardableResult
    func applyToSelection(_ command: SortingCommand, advance: Bool) -> Bool {
        guard let browser, let photoId = browser.selection else { return false }
        apply(command, to: [photoId])
        if advance {
            browser.showNeighbour(offset: 1)
        }
        return true
    }

    /// A menu item, a button or a VoiceOver action on given photos. The files are never touched:
    /// « Rejeter » is only a mark. Returns false when nothing changed (same verdict again, photo
    /// removed meanwhile): nothing is then added to the undo history.
    @discardableResult
    func apply(_ command: SortingCommand, to photoIds: [UUID]) -> Bool {
        let changes = photoIds.map { VerdictChange(photoId: $0, userVerdictRaw: command.userVerdictRaw) }
        do {
            return try save(changes, actionName: command.undoActionName)
        } catch {
            Self.logger.error("Manual verdict not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One photo's new value of `userVerdictRaw`.
    private struct VerdictChange {
        var photoId: UUID
        var userVerdictRaw: String?
    }

    /// Writes the changes, then registers their opposite on the undo manager. Returns false when
    /// every photo already had its value.
    private func save(_ changes: [VerdictChange], actionName: String) throws -> Bool {
        guard let context, !changes.isEmpty else { return false }
        let ids = changes.map(\.photoId)
        let photos = try context.fetch(FetchDescriptor<Photo>(predicate: #Predicate { ids.contains($0.id) }))
        let photosById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })

        var previous: [VerdictChange] = []
        var changed: [Photo] = []
        for change in changes {
            // A photo removed meanwhile (put in the trash by F5) is skipped.
            guard let photo = photosById[change.photoId], photo.userVerdictRaw != change.userVerdictRaw else { continue }
            previous.append(VerdictChange(photoId: photo.id, userVerdictRaw: photo.userVerdictRaw))
            photo.userVerdictRaw = change.userVerdictRaw
            changed.append(photo)
        }
        guard !changed.isEmpty else { return false }
        try context.save()

        // `registerUndo` keeps a closure that puts the previous values back (like pushing an
        // inverse function on a history stack). When ⌘Z runs it, `save` registers the opposite
        // change in turn, and that is what ⇧⌘Z (redo) replays.
        undoManager?.registerUndo(withTarget: self) { sorter in
            sorter.restore(previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        announce(changed)
        return true
    }

    /// Undo or redo: puts the values back and selects the photo again, so the user sees what changed.
    private func restore(_ changes: [VerdictChange], actionName: String) {
        do {
            _ = try save(changes, actionName: actionName)
        } catch {
            Self.logger.error("Manual verdict not restored: \(error.localizedDescription, privacy: .public)")
        }
        if let photoId = changes.first?.photoId {
            browser?.reveal(photoId)
        }
    }

    /// VoiceOver says the new verdict, e.g. « DSC04297.ARW : Garder, votre choix ».
    private func announce(_ photos: [Photo]) {
        guard photos.count == 1, let photo = photos.first, let description = photo.verdictDescription else { return }
        // Like an `aria-live` region: VoiceOver reads the text without moving its cursor.
        AccessibilityNotification.Announcement("\(photo.fileName) : \(description)").post()
    }
}

extension Photo {
    var fileName: String { (relativePath as NSString).lastPathComponent }

    /// True when the user chose the verdict (P, U, X…), even if it is the same as the AI's.
    var isVerdictChosenByUser: Bool { userVerdictRaw != nil }

    /// Spoken and shown in tooltips: « Garder, votre choix, l'IA proposait Rejeter », « Rejeter »,
    /// or nil while the photo is not sorted.
    var verdictDescription: String? {
        guard let verdict else { return nil }
        guard isVerdictChosenByUser else { return verdict.label }
        if let proposal = cullingVerdict, proposal != verdict {
            return String(localized: "\(verdict.label), votre choix, l'IA proposait \(proposal.label)")
        }
        return String(localized: "\(verdict.label), votre choix")
    }
}

/// Number of photos per shown verdict, for the bar above the photos.
struct VerdictCounts: Equatable {
    var keep = 0
    var review = 0
    var reject = 0
    /// Photos whose verdict was chosen by the user.
    var chosenByUser = 0

    init(keep: Int = 0, review: Int = 0, reject: Int = 0, chosenByUser: Int = 0) {
        self.keep = keep
        self.review = review
        self.reject = reject
        self.chosenByUser = chosenByUser
    }

    init(_ photos: [Photo]) {
        for photo in photos {
            switch photo.verdict {
            case .keep: keep += 1
            case .review: review += 1
            case .reject: reject += 1
            case .unknown, nil: break
            }
            if photo.isVerdictChosenByUser { chosenByUser += 1 }
        }
    }

    func count(of verdict: CullingVerdict) -> Int {
        switch verdict {
        case .keep: keep
        case .review: review
        case .reject: reject
        case .unknown: 0
        }
    }
}
