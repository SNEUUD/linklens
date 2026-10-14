import Foundation

/// Writes report.json and report.csv, and formats the terminal summary.
public enum ReportWriter {
    public static func writeJSON(_ report: AnalysisReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    public static func writeCSV(_ report: AnalysisReport, to url: URL) throws {
        let header = [
            "file", "verdict", "main_reason", "all_reasons", "sharpness", "global_sharpness",
            "aesthetics", "is_utility", "faces", "eyes_closed_faces", "face_quality_mean",
            "eye_openness_min", "highlight_clipping", "shadow_clipping", "burst_id", "best_of_burst",
            "burst_score", "capture_date", "preview_source", "sha256",
        ]
        let dateFormatter = ISO8601DateFormatter()
        var lines = [header.joined(separator: ",")]
        for photo in report.photos {
            let qualities = photo.faces.compactMap(\.captureQuality)
            let openness = photo.faces.compactMap(\.eyeOpenness)
            let row: [String] = [
                photo.relativePath,
                photo.verdict.label,
                photo.reasons.first?.message ?? "",
                photo.reasons.map(\.message).joined(separator: " | "),
                number(photo.sharpness, 1),
                number(photo.globalSharpness, 1),
                photo.aesthetics.map { number($0, 3) } ?? "",
                photo.isUtility.map { $0 ? "true" : "false" } ?? "",
                String(photo.faces.count),
                String(photo.faces.filter { $0.eyesClosed == true }.count),
                qualities.isEmpty ? "" : number(qualities.reduce(0, +) / Double(qualities.count), 3),
                openness.min().map { number($0, 3) } ?? "",
                number(photo.highlightClipping, 4),
                number(photo.shadowClipping, 4),
                photo.burstId.map(String.init) ?? "",
                photo.isBestOfBurst ? "true" : "false",
                photo.burstScore.map { number($0, 3) } ?? "",
                photo.captureDate.map { dateFormatter.string(from: $0) } ?? "",
                photo.previewSource.rawValue,
                photo.sha256,
            ]
            lines.append(row.map(escape).joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func summary(_ report: AnalysisReport, outputFolder: URL) -> String {
        let stats = report.stats
        func share(_ count: Int) -> String {
            guard stats.photoCount > 0 else { return "0 %" }
            return (Double(count) / Double(stats.photoCount)).formatted(.percent.precision(.fractionLength(0)))
        }
        let keep = stats.verdictCounts[Verdict.keep.rawValue] ?? 0
        let review = stats.verdictCounts[Verdict.review.rawValue] ?? 0
        let reject = stats.verdictCounts[Verdict.reject.rawValue] ?? 0
        let stages = stats.stageSeconds
        let stageTotal = max(0.000_001, stages.read + stages.hash + stages.pixels + stages.thumbnail + stages.vision)
        func stage(_ name: String, _ seconds: Double) -> String {
            let perPhoto = stats.photoCount > 0 ? seconds / Double(stats.photoCount) * 1000 : 0
            return "    \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(number(perPhoto, 0)) ms/photo  (\(number(seconds / stageTotal * 100, 0)) %)"
        }

        var lines = [
            "",
            "Résumé",
            "  Photos analysées : \(stats.photoCount)" + (stats.failedCount > 0 ? " (\(stats.failedCount) en erreur)" : ""),
            "  Temps total      : \(number(stats.totalSeconds, 1)) s",
            "  Vitesse          : \(number(stats.photosPerSecond, 1)) photos/s (\(stats.concurrency) en parallèle)",
            "  Source des pixels: \(stats.embeddedPreviews) aperçus embarqués, \(stats.decodedImages) décodages complets",
            "",
            "  Garder   : \(keep) (\(share(keep)))",
            "  À revoir : \(review) (\(share(review)))",
            "  Rejeter  : \(reject) (\(share(reject)))",
            "  Rafales  : \(report.bursts.count) (\(report.bursts.reduce(0) { $0 + $1.photos.count }) photos)",
            "",
            "  Temps par étape (cumulé sur toutes les tâches) :",
            stage("Lecture aperçu + EXIF", stages.read),
            stage("SHA-256", stages.hash),
            stage("Netteté + exposition", stages.pixels),
            stage("Miniature", stages.thumbnail),
            stage("Vision", stages.vision),
        ]
        for failure in report.failures {
            lines.append("  ⚠︎ \(failure.relativePath) : \(failure.message)")
        }
        lines += [
            "",
            "Fichiers produits :",
            "  \(outputFolder.appending(path: "report.json").path)",
            "  \(outputFolder.appending(path: "report.csv").path)",
        ]
        return lines.joined(separator: "\n")
    }

    static func number(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
