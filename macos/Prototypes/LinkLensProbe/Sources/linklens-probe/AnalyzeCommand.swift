import ArgumentParser
import Foundation
import ProbeCore

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyse un dossier de photos (JPEG, HEIC, ARW) en lecture seule et produit report.json / report.csv."
    )

    @Argument(help: "Dossier de photos. Il n'est jamais modifié.")
    var folder: String?

    @Option(name: .shortAndLong, help: "Dossier de sortie (rapports et miniatures).")
    var output: String = "probe-output"

    @Option(help: "Fichier JSON de seuils (toutes les clés ou seulement certaines).")
    var thresholds: String?

    @Option(help: "Nombre de photos analysées en parallèle.")
    var concurrency: Int = ProcessInfo.processInfo.activeProcessorCount

    @Flag(help: "Affiche les seuils actuels en JSON, puis quitte.")
    var printThresholds = false

    func validate() throws {
        if !printThresholds && folder == nil {
            throw ValidationError("Indique le dossier de photos à analyser.")
        }
        if concurrency < 1 {
            throw ValidationError("--concurrency doit être au moins 1.")
        }
    }

    func run() async throws {
        let thresholds = try thresholds.map { try Thresholds.load(from: URL(fileURLWithPath: $0)) } ?? Thresholds()
        if printThresholds {
            print(try thresholds.jsonString())
            return
        }
        guard let folder else { return }

        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        let report = try await AnalyzePipeline.run(
            folder: folderURL,
            output: outputURL,
            thresholds: thresholds,
            concurrency: concurrency
        )
        try ReportWriter.writeJSON(report, to: outputURL.appending(path: "report.json"))
        try ReportWriter.writeCSV(report, to: outputURL.appending(path: "report.csv"))
        print(ReportWriter.summary(report, outputFolder: outputURL.standardizedFileURL))
    }
}
