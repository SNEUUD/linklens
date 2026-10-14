import Foundation
import Vision

/// The `analyze` command: scan → parallel analysis → bursts → culling → report.
public enum AnalyzePipeline {
    public static func run(
        folder: URL,
        output: URL,
        thresholds: Thresholds,
        concurrency: Int
    ) async throws -> AnalysisReport {
        // The source folder is read-only: refuse to write anything inside it.
        guard FileManager.default.fileExists(atPath: folder.path) else { throw ProbeError.folderNotFound(folder.path) }
        guard !PhotoScanner.isInside(output, folder) else {
            throw ProbeError.outputInsideSource(output: output.path, source: folder.path)
        }
        let thumbsFolder = output.appending(path: "thumbs")
        try FileManager.default.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)

        let files = try PhotoScanner.scan(folder: folder)
        let clock = ContinuousClock()
        let start = clock.now
        let progress = ProgressReporter(total: files.count, label: "Analyse")
        let limit = max(1, concurrency)

        // Result of one task: success or failure, never a thrown error (one bad file must not stop the run).
        enum Outcome: Sendable {
            case success(PhotoAnalysis)
            case failure(AnalysisFailure)
        }

        var analyses: [PhotoAnalysis] = []
        var failures: [AnalysisFailure] = []

        // Task group = Promise.all with a concurrency limit: at most `limit` photos in flight.
        await withTaskGroup(of: Outcome.self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < files.count else { return }
                let file = files[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        return .success(try await PhotoAnalyzer.analyze(file, thresholds: thresholds, thumbsFolder: thumbsFolder))
                    } catch {
                        return .failure(AnalysisFailure(relativePath: file.relativePath, message: error.localizedDescription))
                    }
                }
            }

            for _ in 0..<limit { startNext() }
            while let outcome = await group.next() {
                switch outcome {
                case .success(let analysis):
                    analyses.append(analysis)
                    await progress.advance()
                case .failure(let failure):
                    failures.append(failure)
                    await progress.advance(failed: true)
                }
                if !Task.isCancelled { startNext() }
            }
        }
        try Task.checkCancellation()

        // Chronological order (file name breaks ties: the A6000 has no sub-seconds).
        analyses.sort { a, b in
            let dateA = a.metadata.captureDate ?? .distantFuture
            let dateB = b.metadata.captureDate ?? .distantFuture
            if dateA != dateB { return dateA < dateB }
            return a.file.relativePath.localizedStandardCompare(b.file.relativePath) == .orderedAscending
        }

        // Neighbour comparisons, then bursts and verdicts (sequential: needs every photo).
        var secondsApart: [Double?] = []
        var distances: [Double?] = []
        for (current, next) in zip(analyses, analyses.dropFirst()) {
            if let a = current.metadata.captureDate, let b = next.metadata.captureDate {
                secondsApart.append(b.timeIntervalSince(a))
            } else {
                secondsApart.append(nil)
            }
            if let a = current.vision.featurePrint, let b = next.vision.featurePrint {
                distances.append(try? a.distance(to: b))
            } else {
                distances.append(nil)
            }
        }
        let groups = analyses.isEmpty ? [] : BurstGrouper.group(secondsApart: secondsApart, distances: distances, thresholds: thresholds)
        let (photos, bursts) = Classifier.classify(analyses, bursts: groups, thresholds: thresholds)

        let neighborDistances = secondsApart.indices.map { i in
            NeighborDistance(
                from: analyses[i].file.relativePath,
                to: analyses[i + 1].file.relativePath,
                secondsApart: secondsApart[i],
                distance: distances[i],
                sameBurst: photos[i].burstId != nil && photos[i].burstId == photos[i + 1].burstId
            )
        }

        let totalSeconds = start.duration(to: clock.now).seconds
        var verdictCounts: [String: Int] = [:]
        for verdict in Verdict.allCases { verdictCounts[verdict.rawValue] = photos.filter { $0.verdict == verdict }.count }

        let stats = RunStats(
            photoCount: photos.count,
            failedCount: failures.count,
            totalSeconds: totalSeconds,
            photosPerSecond: totalSeconds > 0 ? Double(photos.count) / totalSeconds : 0,
            concurrency: limit,
            verdictCounts: verdictCounts,
            stageSeconds: analyses.map(\.timings).reduce(StageTimings(), +),
            embeddedPreviews: analyses.filter { $0.previewSource == .embedded }.count,
            decodedImages: analyses.filter { $0.previewSource == .decoded }.count
        )
        return AnalysisReport(
            generatedAt: Date(),
            sourceFolder: folder.path,
            thresholds: thresholds,
            stats: stats,
            bursts: bursts,
            neighborDistances: neighborDistances,
            failures: failures.sorted { $0.relativePath < $1.relativePath },
            photos: photos
        )
    }
}
