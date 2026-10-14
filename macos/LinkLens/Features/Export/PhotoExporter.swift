import CoreImage
import Foundation

/// Kind of file to export, from its extension.
///
/// Only photos are indexed for now. Videos arrive with F1 (SD card): `exportVideo` will then
/// convert them with AVFoundation (H.264 or HEVC) next to the photos, without changing this API.
enum MediaKind: Sendable, Equatable {
    case photo
    case video

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mts"]

    init(relativePath: String) {
        let fileExtension = (relativePath as NSString).pathExtension.lowercased()
        self = Self.videoExtensions.contains(fileExtension) ? .video : .photo
    }
}

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
}

struct ExportProgress: Sendable, Equatable {
    var galleryId: UUID
    var preset: ExportPreset
    var completed: Int
    var total: Int

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
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
    case videoNotSupportedYet(String)

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable(let name):
            String(localized: "Le dossier « \(name) » n'est plus disponible. Choisissez-en un autre.")
        case .videoNotSupportedYet(let name):
            String(localized: "L'export des vidéos n'est pas encore disponible (« \(name) »).")
        }
    }
}

/// F6: converts photos of a gallery into a folder chosen by the user, several at a time.
///
/// The originals are only read, through the gallery's bookmark. Each file is first written under a
/// hidden temporary name in the destination, then given its final name without ever replacing an
/// existing file. An unreadable photo never stops the export: it is listed in `failures`.
struct PhotoExporter: Sendable {
    /// Photos converted at the same time. Developing a 24 Mpx RAW uses about 200 MB of memory.
    var concurrency = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

    // `@concurrent` runs this function on a background thread, even when called from the
    // `MainActor`: the interface stays responsive (no equivalent in JavaScript, which has one thread).
    @concurrent
    func export(
        _ request: ExportRequest,
        onProgress: @MainActor @Sendable (ExportProgress) -> Void = { _ in }
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
        let existingNames = Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
        let names = ExportNaming.plan(
            request.items.map(\.relativePath), fileExtension: settings.format.fileExtension, existingNames: existingNames
        )
        let jobs = zip(request.items, names).enumerated().map { index, pair in
            Job(index: index, item: pair.0, plannedName: pair.1)
        }
        let context = CIContext(options: [.cacheIntermediates: false, .name: "LinkLens export"])

        // Result of one task: never a thrown error, so one photo cannot stop the others.
        enum Outcome: Sendable {
            case exported(index: Int, file: URL)
            case failed(ExportFailure)
            case skipped
        }

        var exported: [(index: Int, file: URL)] = []
        var failures: [ExportFailure] = []
        var completed = 0
        await onProgress(ExportProgress(galleryId: request.galleryId, preset: request.preset, completed: 0, total: jobs.count))

        // Same pattern as the AI sorting: a task group with at most `concurrency` children at once
        // (like `Promise.all` with a limit). Cancelling the parent task cancels every child.
        await withTaskGroup(of: Outcome.self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < jobs.count else { return }
                let job = jobs[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return .skipped }
                    do {
                        let file = try Self.export(job, from: folder, to: destination, settings: settings, context: context)
                        return .exported(index: job.index, file: file)
                    } catch {
                        return .failed(ExportFailure(relativePath: job.item.relativePath, message: error.localizedDescription))
                    }
                }
            }

            for _ in 0..<max(1, concurrency) { startNext() }
            while let outcome = await group.next() {
                switch outcome {
                case .exported(let index, let file): exported.append((index, file))
                case .failed(let failure): failures.append(failure)
                case .skipped: break
                }
                completed += 1
                await onProgress(ExportProgress(
                    galleryId: request.galleryId, preset: request.preset, completed: completed, total: jobs.count
                ))
                if !Task.isCancelled { startNext() }
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

    private static func export(
        _ job: Job,
        from folder: URL,
        to destination: URL,
        settings: PhotoOutputSettings,
        context: CIContext
    ) throws -> URL {
        let source = folder.appending(path: job.item.relativePath)
        switch job.item.kind {
        case .photo:
            break
        case .video:
            // Comes with F1: AVAssetExportSession, H.264 or HEVC.
            throw ExportError.videoNotSupportedYet(source.lastPathComponent)
        }

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
