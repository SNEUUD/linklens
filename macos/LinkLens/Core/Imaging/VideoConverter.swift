import AVFoundation
import Foundation

enum VideoConversionError: LocalizedError, Equatable {
    /// AVCHD (.mts), a damaged file or a codec AVFoundation cannot read: the user copies it by hand.
    case unsupportedFormat(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            String(localized: "« \(name) » — Format non pris en charge : copiez ce fichier tel quel depuis le Finder.")
        case .exportFailed(let name):
            String(localized: "Impossible de convertir la vidéo « \(name) ».")
        }
    }
}

/// Converts one video file into a new `.mp4` file with `AVAssetExportSession`. The source is only read.
///
/// The hardware encoder is shared by the whole Mac: the export runs one video at a time.
enum VideoConverter {
    /// Writes `source` to `output` (which must not exist yet). `keepsLocation == false` removes the
    /// GPS position and other personal metadata (`AVMetadataItemFilter.forSharing()`); the recording
    /// date stays. `onProgress` receives 0…1 while the file is written.
    ///
    /// Cancelling the calling task stops the export; the partial `output` may remain, the caller
    /// removes it (it writes to a hidden temporary name).
    static func convert(
        _ source: URL,
        to output: URL,
        preset: VideoExportPreset,
        keepsLocation: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        // Asks AVFoundation whether it can read this file and write it in this format, without starting.
        guard await AVAssetExportSession.compatibility(
            ofExportPreset: preset.sessionPreset, with: asset, outputFileType: preset.fileType
        ), let session = AVAssetExportSession(asset: asset, presetName: preset.sessionPreset) else {
            throw VideoConversionError.unsupportedFormat(name)
        }
        if !keepsLocation {
            session.metadataItemFilter = .forSharing()
        }
        let shared = SharedExportSession(session: session)

        // Two things at once: the export, and a loop that reads its progress four times a second.
        // `states(updateInterval:)` is an `AsyncSequence`: `for await` reads it like
        // `for await (const x of stream)` in TypeScript. The loop stops with the export (`defer`).
        let progressLoop = Task {
            for await state in shared.session.states(updateInterval: 0.25) {
                if Task.isCancelled { break }
                if case .exporting(let progress) = state {
                    await onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progressLoop.cancel() }

        do {
            // `withTaskCancellationHandler` runs its `onCancel` as soon as the task is cancelled
            // (« Annuler »), even in the middle of the export, like an `AbortSignal` listener.
            try await withTaskCancellationHandler {
                try await session.export(to: output, as: preset.fileType)
            } onCancel: {
                shared.session.cancelExport()
            }
        } catch {
            throw Task.isCancelled ? CancellationError() : VideoConversionError.exportFailed(name)
        }
        // A cancellation that arrived just as the file was finished: treated as cancelled all the same.
        try Task.checkCancellation()
    }
}

/// Lets the progress loop and « Annuler » reach the session from other tasks.
///
/// `AVAssetExportSession` is not marked `Sendable` (safe to share between threads), yet Apple documents
/// its progress (`states(updateInterval:)`) and `cancelExport()` as made to be called while the export
/// runs. `@unchecked Sendable` tells the compiler "trust me" for this one value, like a `// @ts-expect-error`
/// limited to what is listed here; the session is never changed from these other tasks.
private struct SharedExportSession: @unchecked Sendable {
    let session: AVAssetExportSession
}
