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
    func chooseDestinationAndExport(
        _ items: [ExportItem], of gallery: Gallery, preset: ExportPreset, videoPreset: VideoExportPreset = .compatible
    ) {
        guard !isExporting, !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Exporter ici")
        let videoCount = items.filter { $0.kind == .video }.count
        let photoCount = items.count - videoCount
        if videoCount == 0 {
            panel.message = String(localized: "Choisissez le dossier où enregistrer les photos (\(items.count)) en \(String(localized: preset.title)). Les originaux ne sont pas modifiés.")
        } else if photoCount == 0 {
            panel.message = String(inflecting: "Choisissez le dossier où enregistrer ^[\(videoCount) vidéo](inflect: true) (« \(String(localized: videoPreset.title)) »). Les originaux ne sont pas modifiés.")
        } else {
            panel.message = String(inflecting: "Choisissez le dossier où enregistrer ^[\(photoCount) photo](inflect: true) en \(String(localized: preset.title)) et ^[\(videoCount) vidéo](inflect: true) (« \(String(localized: videoPreset.title)) »). Les originaux ne sont pas modifiés.")
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        start(ExportRequest(
            galleryId: gallery.id,
            galleryName: gallery.name,
            folderPath: gallery.folderPath,
            folderBookmark: gallery.folderBookmark,
            items: items,
            preset: preset,
            destination: destination,
            videoPreset: videoPreset
        ))
    }

    /// Starts an export without asking anything (the folder is already chosen).
    func start(_ request: ExportRequest) {
        guard !isExporting else { return }
        summary = nil
        startedAt = .now
        task = Task {
            do {
                // The task already holds the controller until the export ends: no `weak` needed here.
                summary = try await exporter.export(request) { progress in
                    self.progress = progress
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

    /// The files already written are kept; the video being written is stopped and removed.
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

    /// Interface renders only: shows the result of an export that did not run.
    func showSummaryForRenders(_ summary: ExportSummary, finishedAt: Date) {
        self.summary = summary
        self.finishedAt = finishedAt
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
