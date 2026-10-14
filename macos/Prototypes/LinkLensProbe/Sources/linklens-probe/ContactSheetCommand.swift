import ArgumentParser
import Foundation
import ProbeCore

struct ContactSheetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contact-sheet",
        abstract: "Génère une planche-contact HTML à partir d'un report.json."
    )

    @Argument(help: "Chemin du report.json produit par analyze.")
    var report: String

    func run() async throws {
        let reportURL = URL(fileURLWithPath: report)
        let analysis = try AnalysisReport.load(from: reportURL)
        // Next to report.json, so that the relative "thumbs/…" paths work.
        let htmlURL = reportURL.deletingLastPathComponent().appending(path: "contact-sheet.html")
        try ContactSheet.html(for: analysis).write(to: htmlURL, atomically: true, encoding: .utf8)
        print("Planche-contact : \(htmlURL.standardizedFileURL.path)")
        print("Pour l'ouvrir : open \"\(htmlURL.standardizedFileURL.path)\"")
    }
}
