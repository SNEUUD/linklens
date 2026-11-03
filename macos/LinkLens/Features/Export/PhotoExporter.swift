import AVFoundation
import CoreImage
import Foundation

/// One file to export, as a `Sendable` copy of the `Photo` (see `PhotoReference`).
struct ExportItem: Sendable, Equatable {
    var photoId: UUID
    /// Path relative to the gallery folder.
    var relativePath: String

    var kind: MediaKind { MediaKind(relativePath: relativePath) }
}

/// Everything an export needs, taken from the interface before it starts.
struct ExportRequest: Sendable {
    var galleryId: UUID
    var galleryName: String
    var folderPath: String
    /// The gallery's bookmark: the originals are read through it, never written.
    var folderBookmark: Data
    var items: [ExportItem]
    var preset: ExportPreset
    /// Folder chosen by the user in the folder picker: the only place written to.
    var destination: URL
    /// Format of the videos of `items`. A default value: requests without videos need not give it.
    var videoPreset: VideoExportPreset = .compatible
}

struct ExportProgress: Sendable, Equatable {
    var galleryId: UUID
    var preset: ExportPreset
    var completed: Int
    var total: Int
    /// How much of the video being written is done (0…1), nil when no video is being written. A long
    /// video takes minutes: the bar moves during it instead of waiting for the next file.
    var currentFileFraction: Double? = nil

    var fraction: Double {
        total == 0 ? 0 : min(1, (Double(completed) + (currentFileFraction ?? 0)) / Double(total))
    }
}

struct ExportFailure: Sendable, Equatable {
    var relativePath: String
    var message: String
}

/// Outcome of an export, shown once it is over.
struct ExportSummary: Sendable, Equatable {
    var galleryId: UUID
    var preset: ExportPreset
    var destination: URL
    /// Written files, in the order of the request.
    var exportedFiles: [URL]
    var failures: [ExportFailure]
    /// Stopped by "Annuler": the files already written are kept.
    var wasCancelled: Bool
}

enum ExportError: LocalizedError, Equatable {
    case destinationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable(let name):
            String(localized: "Le dossier « \(name) » n'est plus disponible. Choisissez-en un autre.")
        }
    }
}

/// F6: converts photos and videos of a gallery into a folder chosen by the user, several at a time.
///
/// The originals are only read, through the gallery's bookmark. Each file is first written under a
/// hidden temporary name in the destination, then given its final name without ever replacing an
/// existing file. An unreadable file never stops the export: it is listed in `failures`.
///
/// Photos are converted `concurrency` at a time; videos one at a time, next to the photos (the Mac's
/// video encoder is shared: two videos at once would not go faster).
struct PhotoExporter: Sendable {
    /// Photos converted at the same time. Developing a 24 Mpx RAW uses about 200 MB of memory.
    var concurrency = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

    // `@concurrent` runs this function on a background thread, even when called from the
    // `MainActor`: the interface stays responsive (no equivalent in JavaScript, which has one thread).
    @concurrent
    func export(
        _ request: ExportRequest,
        onProgress: @escaping @MainActor @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> ExportSummary {
        // A bookmark to a deleted folder or an unplugged disk (F9) does not resolve.
        guard let folder = try? FolderBookmark.resolve(request.folderBookmark) else {
            throw LibraryError.folderNotFound(request.folderPath)
        }
        guard folder.startAccessingSecurityScopedResource() else {
            throw LibraryError.accessDenied(request.galleryName)
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw LibraryError.folderNotFound(request.folderPath)
        }

        // The folder picker already granted access for this launch; it may also be a scoped URL.
        let destination = request.destination
        let isAccessingDestination = destination.startAccessingSecurityScopedResource()
        defer {
            if isAccessingDestination { destination.stopAccessingSecurityScopedResource() }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportError.destinationUnavailable(destination.lastPathComponent)
        }

        let settings = request.preset.settings
        let videoPreset = request.videoPreset
        let existingNames = Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
        let names = ExportNaming.plan(
            request.items.map { item in
                (item.relativePath, item.kind == .video ? videoPreset.fileExtension : settings.format.fileExtension)
            },
            existingNames: existingNames
        )
        let jobs = zip(request.items, names).enumerated().map { index, pair in
            Job(index: index, item: pair.0, plannedName: pair.1)
        }
        let photoJobs = jobs.filter { $0.item.kind != .video }
        let videoJobs = jobs.filter { $0.item.kind == .video }
        let context = CIContext(options: [.cacheIntermediates: false, .name: "LinkLens export"])
        let reporter = ExportProgressReporter(
            start: ExportProgress(galleryId: request.galleryId, preset: request.preset, completed: 0, total: jobs.count),
            onProgress: onProgress
        )

        var exported: [(index: Int, file: URL)] = []
        var failures: [ExportFailure] = []
        await reporter.reportStart()

        // Same pattern as the AI sorting: a task group with a limited number of children at once
        // (like `Promise.all` with a limit). Two lanes share it: photos (`concurrency` at a time) and
        // videos (one at a time). Cancelling the parent task cancels every child.
        await withTaskGroup(of: Outcome.self) { group in
            var nextPhoto = 0
            var nextVideo = 0
            func startNextPhoto() {
                guard nextPhoto < photoJobs.count else { return }
                let job = photoJobs[nextPhoto]
                nextPhoto += 1
                group.addTask {
                    guard !Task.isCancelled else { return Outcome(job: job, lane: .photo, result: .skipped) }
                    do {
                        let file = try Self.exportPhoto(job, from: folder, to: destination, settings: settings, context: context)
                        return Outcome(job: job, lane: .photo, result: .exported(file))
                    } catch {
                        return Outcome(job: job, lane: .photo, result: .failed(error.localizedDescription))
                    }
                }
            }
            func startNextVideo() {
                guard nextVideo < videoJobs.count else { return }
                let job = videoJobs[nextVideo]
                nextVideo += 1
                group.addTask {
                    guard !Task.isCancelled else { return Outcome(job: job, lane: .video, result: .skipped) }
                    do {
                        let file = try await Self.exportVideo(
                            job, from: folder, to: destination, preset: videoPreset, keepsLocation: settings.keepsLocation
                        ) { fraction in
                            await reporter.reportVideo(index: job.index, fraction: fraction)
                        }
                        return Outcome(job: job, lane: .video, result: .exported(file))
                    } catch is CancellationError {
                        return Outcome(job: job, lane: .video, result: .skipped)
                    } catch {
                        return Outcome(job: job, lane: .video, result: .failed(error.localizedDescription))
                    }
                }
            }

            for _ in 0..<max(1, concurrency) { startNextPhoto() }
            startNextVideo()
            while let outcome = await group.next() {
                switch outcome.result {
                case .exported(let file): exported.append((outcome.job.index, file))
                case .failed(let message): failures.append(ExportFailure(relativePath: outcome.job.item.relativePath, message: message))
                case .skipped: break
                }
                await reporter.reportFinished(index: outcome.job.index, lane: outcome.lane)
                guard !Task.isCancelled else { continue }
                switch outcome.lane {
                case .photo: startNextPhoto()
                case .video: startNextVideo()
                }
            }
        }

        return ExportSummary(
            galleryId: request.galleryId,
            preset: request.preset,
            destination: destination,
            exportedFiles: exported.sorted { $0.index < $1.index }.map(\.file),
            failures: failures,
            wasCancelled: Task.isCancelled
        )
    }

    private struct Job: Sendable {
        var index: Int
        var item: ExportItem
        var plannedName: String
    }

    enum Lane: Sendable {
        case photo
        case video
    }

    /// Result of one task: never a thrown error, so one file cannot stop the others.
    private struct Outcome: Sendable {
        enum Result: Sendable {
            case exported(URL)
            case failed(String)
            case skipped
        }

        var job: Job
        var lane: Lane
        var result: Result
    }

    private static func exportPhoto(
        _ job: Job,
        from folder: URL,
        to destination: URL,
        settings: PhotoOutputSettings,
        context: CIContext
    ) throws -> URL {
        // An unknown file is tried as a photo: the conversion error says what went wrong.
        let source = folder.appending(path: job.item.relativePath)
        // A hidden name: an interrupted export never leaves a half-written photo with a real name.
        let temporary = destination.appending(path: ".\(job.plannedName).linklens-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) } // nothing left once moved
        try PhotoConverter.convert(source, to: temporary, settings: settings, context: context)
        return try moveWithoutReplacing(
            temporary,
            into: destination,
            plannedName: job.plannedName,
            base: ExportNaming.baseName(of: job.item.relativePath),
            fileExtension: settings.format.fileExtension
        )
    }

    private static func exportVideo(
        _ job: Job,
        from folder: URL,
        to destination: URL,
        preset: VideoExportPreset,
        keepsLocation: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let source = folder.appending(path: job.item.relativePath)
        // Hidden too, and ending in « .mp4 » so AVFoundation recognises the file type it writes.
        let temporary = destination.appending(
            path: ".\(job.plannedName).linklens-\(UUID().uuidString).tmp.\(preset.fileExtension)"
        )
        // Runs on every way out: finished (the file was moved, nothing to remove), failed or cancelled.
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await VideoConverter.convert(source, to: temporary, preset: preset, keepsLocation: keepsLocation, onProgress: onProgress)
        return try moveWithoutReplacing(
            temporary,
            into: destination,
            plannedName: job.plannedName,
            base: ExportNaming.baseName(of: job.item.relativePath),
            fileExtension: preset.fileExtension
        )
    }

    /// Gives `file` its planned name, or the next free "name (n)" if a file of that name appeared
    /// since the export started (another app writing to the same folder).
    static func moveWithoutReplacing(
        _ file: URL,
        into folder: URL,
        plannedName: String,
        base: String,
        fileExtension: String
    ) throws -> URL {
        for number in 1...10_000 {
            let name = number == 1 ? plannedName : ExportNaming.candidate(base: base, fileExtension: fileExtension, number: number)
            let target = folder.appending(path: name)
            do {
                // `moveItem` refuses to replace an existing file: it throws `fileWriteFileExists`.
                try FileManager.default.moveItem(at: file, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw ConversionError.writeFailed(plannedName)
    }
}

/// Gathers the progress of both lanes on the `MainActor`, where `onProgress` runs: the counts are
/// only changed there, one call after the other, so they never mix up.
///
/// A `@MainActor` class is used from the background through `await` (like posting a message to the
/// UI thread); `nonisolated init` lets the background code create it without waiting.
@MainActor
private final class ExportProgressReporter {
    private var progress: ExportProgress
    private let onProgress: @MainActor @Sendable (ExportProgress) -> Void
    /// Files already counted: a late progress report of a finished video is ignored.
    private var finished: Set<Int> = []

    nonisolated init(start: ExportProgress, onProgress: @escaping @MainActor @Sendable (ExportProgress) -> Void) {
        progress = start
        self.onProgress = onProgress
    }

    func reportStart() {
        onProgress(progress)
    }

    /// The video `index` is `fraction` done.
    func reportVideo(index: Int, fraction: Double) {
        guard !finished.contains(index) else { return }
        progress.currentFileFraction = min(max(fraction, 0), 1)
        onProgress(progress)
    }

    func reportFinished(index: Int, lane: PhotoExporter.Lane) {
        finished.insert(index)
        progress.completed += 1
        if lane == .video { progress.currentFileFraction = nil }
        onProgress(progress)
    }
}
