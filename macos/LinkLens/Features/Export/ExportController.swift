import AppKit
import Observation

/// Drives "Exporter": destination folder picker, background export, progress, cancellation and the
/// summary shown at the end. One export at a time for the whole app.
@MainActor
@Observable
final class ExportController {
    var errorMessage: String?
    private(set) var progress: ExportProgress?
    /// Result of the last export, shown until the user closes it.
    private(set) var summary: ExportSummary?
    /// When the running export started, then when it ended: the progress pill shows the most recent work.
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    @ObservationIgnored private let exporter: PhotoExporter
    @ObservationIgnored private var task: Task<Void, Never>?

    var isExporting: Bool { task != nil }

    init(exporter: PhotoExporter = PhotoExporter()) {
        self.exporter = exporter
    }

    /// Asks where to save, then exports in the background.
    func chooseDestinationAndExport(_ items: [ExportItem], of gallery: Gallery, preset: ExportPreset) {
        guard !isExporting, !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Exporter ici")
        panel.message = String(localized: "Choisissez le dossier où enregistrer les photos (\(items.count)) en \(String(localized: preset.title)). Les originaux ne sont pas modifiés.")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        start(ExportRequest(
            galleryId: gallery.id,
            galleryName: gallery.name,
            folderPath: gallery.folderPath,
            folderBookmark: gallery.folderBookmark,
            items: items,
            preset: preset,
            destination: destination
        ))
    }

    /// Starts an export without asking anything (the folder is already chosen).
    func start(_ request: ExportRequest) {
        guard !isExporting else { return }
        summary = nil
        startedAt = .now
        task = Task {
            do {
                summary = try await exporter.export(request) { [weak self] progress in
                    self?.progress = progress
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            progress = nil
            finishedAt = .now
            task = nil
        }
    }

    /// Waits for the running export (used by the tests).
    func waitUntilFinished() async {
        await task?.value
    }

    /// The photos already written are kept.
    func cancel() {
        task?.cancel()
    }

    func dismissSummary() {
        summary = nil
    }

    #if DEBUG
    /// Interface renders only (`InterfaceRenderTests`): shows an export in progress without exporting.
    /// `#if DEBUG` keeps this out of the version sent to the App Store.
    func showProgressForRenders(_ progress: ExportProgress, startedAt: Date) {
        self.progress = progress
        self.startedAt = startedAt
    }
    #endif

    /// Opens the destination in the Finder with the exported files selected.
    func revealExportedFiles() {
        guard let summary else { return }
        let destination = summary.destination
        let isAccessing = destination.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { destination.stopAccessingSecurityScopedResource() }
        }
        if summary.exportedFiles.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(summary.exportedFiles)
        }
    }
}
