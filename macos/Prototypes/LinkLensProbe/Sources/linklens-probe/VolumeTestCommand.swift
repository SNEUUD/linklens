import ArgumentParser
import Foundation
import ProbeCore

struct VolumeTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume-test",
        abstract: "Insère des photos fictives dans SwiftData (par lots, dans un ModelActor) et mesure les performances."
    )

    @Option(help: "Nombre de photos à insérer.")
    var count: Int = 10_000

    @Option(help: "Nombre de galeries (séances).")
    var galleries: Int = 20

    @Option(help: "Taille des lots d'insertion.")
    var batchSize: Int = 500

    @Option(name: .shortAndLong, help: "Dossier de sortie (la base de test y est recréée à chaque lancement).")
    var output: String = "probe-output"

    func validate() throws {
        guard count >= 1, galleries >= 1, batchSize >= 1 else {
            throw ValidationError("--count, --galleries et --batch-size doivent être au moins 1.")
        }
        guard galleries <= count else {
            throw ValidationError("Il faut au moins une photo par galerie.")
        }
    }

    func run() async throws {
        let storeURL = URL(fileURLWithPath: output, isDirectory: true).appending(path: "volume-test.store")
        let result = try await VolumeTest.run(count: count, galleryCount: galleries, batchSize: batchSize, storeURL: storeURL)
        print(result.summary)
    }
}
