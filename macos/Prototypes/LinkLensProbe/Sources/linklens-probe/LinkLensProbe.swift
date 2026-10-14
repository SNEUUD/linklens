import ArgumentParser

@main
struct LinkLensProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "linklens-probe",
        abstract: "Prototype LinkLens : qualité du tri IA (Vision) et performances SwiftData.",
        subcommands: [AnalyzeCommand.self, ContactSheetCommand.self, VolumeTestCommand.self]
    )
}
