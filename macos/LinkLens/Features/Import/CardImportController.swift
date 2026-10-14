import AppKit
import Observation

/// Drives « Importer la carte »: consent to read the card, the import sheet, the copy in the
/// background, cancellation and the final report.
///
/// The sandbox does not let the app read a card on its own. The folder picker is opened on the card
/// itself: one click on « Autoriser » gives access for this launch, with no extra entitlement.
@MainActor
@Observable
final class CardImportController {
    /// Steps of the import sheet. An `enum` with associated values is like a TypeScript
    /// discriminated union (`{ kind: "ready", card } | { kind: "finished", report } | …`).
    enum Stage: Equatable {
        case idle
        case scanning(cardName: String)
        case ready(CardContents)
        case importing(CardContents)
        case finished(CardImportReport)
    }

    private(set) var stage: Stage = .idle
    var sessionName = ""
    var sessionDate = Date()
    /// Location of this import (the default one unless changed in the sheet).
    private(set) var destination: ImportDestination?
    private(set) var defaultDestination: ImportDestination?
    /// Also make the location chosen in the sheet the default one.
    var makeDestinationDefault = false
    private(set) var progress: CardImportProgress?
    /// Shown in the sheet after a cancellation.
    private(set) var notice: String?
    var errorMessage: String?

    @ObservationIgnored private let importer: CardImporter
    @ObservationIgnored private let destinations: ImportDestinationStore
    @ObservationIgnored private let onGalleryImported: @MainActor (UUID) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    var isSheetPresented: Bool { stage != .idle }
    var isBusy: Bool { task != nil }
    var isImporting: Bool {
        if case .importing = stage { return true }
        return false
    }

    init(
        importer: CardImporter,
        destinations: ImportDestinationStore = ImportDestinationStore(),
        onGalleryImported: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.importer = importer
        self.destinations = destinations
        self.onGalleryImported = onGalleryImported
    }

    // MARK: - Choosing the card

    /// A detected card: the picker opens on it. Returns false if the user cancelled the picker.
    @discardableResult
    func importCard(_ card: DetectedCard) -> Bool {
        askForCard(directory: card.url, name: card.name)
    }

    /// « Importer une carte… » from the menu: the picker opens on the list of disks.
    func chooseCard() {
        askForCard(directory: URL(filePath: "/Volumes", directoryHint: .isDirectory), name: nil)
    }

    @discardableResult
    private func askForCard(directory: URL, name: String?) -> Bool {
        guard !isBusy, !isSheetPresented else { return false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        if let name {
            panel.prompt = String(localized: "Autoriser")
            panel.message = String(localized: "Pour copier les photos de la carte « \(name) », cliquez sur « Autoriser » sans changer de dossier. Rien ne sera modifié sur la carte.")
        } else {
            panel.prompt = String(localized: "Importer")
            panel.message = String(localized: "Choisissez la carte de l'appareil photo (le disque qui contient le dossier DCIM). Rien ne sera modifié sur la carte.")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        scan(url)
        return true
    }

    private func scan(_ card: URL) {
        stage = .scanning(cardName: card.lastPathComponent)
        notice = nil
        task = Task {
            do {
                let contents = try await Self.scanCard(card)
                guard !contents.files.isEmpty else {
                    throw CardImportError.emptyCard(contents.name)
                }
                sessionName = ""
                sessionDate = contents.earliestDate ?? Date()
                defaultDestination = destinations.load()
                destination = defaultDestination
                makeDestinationDefault = false
                stage = .ready(contents)
            } catch {
                stage = .idle
                errorMessage = error.localizedDescription
            }
            task = nil
        }
    }

    /// Reads the card off the main thread (EXIF headers of hundreds of photos).
    @concurrent
    private static func scanCard(_ url: URL) async throws -> CardContents {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        return try CardScanner.scan(card: url)
    }

    // MARK: - Destination

    /// Picks the location of this gallery. The very first one becomes the default location.
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination?.url
        panel.prompt = String(localized: "Choisir")
        panel.message = String(localized: "Choisissez où ranger vos galeries : un dossier de ce Mac ou d'un disque externe. LinkLens y crée un dossier par année, puis un par séance.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            destination = ImportDestination(url: url, bookmark: try FolderBookmark.createReadWrite(for: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "2026 › 2026-10-14 Mariage Julie & Tom": where the files will go, inside the location.
    var plannedFolder: String {
        let names = ImportLayout.folderNames(date: sessionDate, sessionName: sessionName)
        return "\(names.year) › \(names.session)"
    }

    // MARK: - Import

    func startImport() {
        guard case .ready(let card) = stage, let destination, !isBusy else { return }
        if defaultDestination == nil || makeDestinationDefault {
            destinations.save(destination)
            defaultDestination = destination
        }
        let request = CardImportRequest(card: card, destination: destination.url, sessionName: sessionName, sessionDate: sessionDate)
        stage = .importing(card)
        notice = nil
        task = Task {
            do {
                let report = try await importer.importCard(request) { [weak self] progress in
                    self?.progress = progress
                }
                stage = .finished(report)
                if let galleryId = report.galleryId {
                    onGalleryImported(galleryId)
                }
            } catch is CancellationError {
                stage = .ready(card)
                notice = String(localized: "Import annulé. Les copies déjà faites ont été supprimées de l'emplacement choisi ; la carte n'a pas été modifiée.")
            } catch {
                stage = .ready(card)
                errorMessage = error.localizedDescription
            }
            progress = nil
            task = nil
        }
    }

    /// Stops the copy (the partial copies are removed), or closes the sheet before the import.
    func cancel() {
        if isImporting {
            task?.cancel()
        } else if !isBusy {
            close()
        }
    }

    func close() {
        guard !isImporting else { return }
        stage = .idle
        notice = nil
    }

    /// Waits for the running step (used by the tests).
    func waitUntilFinished() async {
        await task?.value
    }

    /// Opens the session folder in the Finder.
    func revealInFinder(_ report: CardImportReport) {
        let scope = destination?.url
        let isAccessing = scope?.startAccessingSecurityScopedResource() ?? false
        defer { if isAccessing { scope?.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([report.sessionFolder])
    }
}
