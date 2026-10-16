import SwiftUI

/// The import sheet: settings, then progress, then the report.
struct CardImportSheet: View {
    @Environment(CardImportController.self) private var controller

    var body: some View {
        Group {
            switch controller.stage {
            case .idle:
                EmptyView()
            case .scanning(let cardName):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Lecture de la carte « \(cardName) »…")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .ready(let card):
                CardImportForm(card: card)
            case .importing(let card):
                CardImportProgressView(card: card, progress: controller.progress)
            case .finished(let report):
                CardImportReportView(report: report)
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled(controller.isImporting)
    }
}

/// Before the import: session name and date, location, and what will be copied.
private struct CardImportForm: View {
    @Environment(CardImportController.self) private var controller
    let card: CardContents

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Importer la carte « \(card.name) »")
                    .font(.title2.bold())
                Text(summary)
                    .foregroundStyle(.secondary)
            }

            if let notice = controller.notice {
                Label(notice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Nom de la séance", text: $controller.sessionName, prompt: Text("Mariage Julie & Tom"))
                DatePicker("Date de la séance", selection: $controller.sessionDate, displayedComponents: .date)
                LabeledContent("Emplacement") {
                    HStack {
                        if let destination = controller.destination {
                            Text(verbatim: destination.displayPath)
                                .lineLimit(2)
                                .truncationMode(.head)
                                .textSelection(.enabled)
                        } else {
                            Text("Aucun emplacement choisi")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(controller.destination == nil ? "Choisir…" : "Changer…", action: controller.chooseDestination)
                    }
                }
                if controller.destination != nil, controller.defaultDestination != nil,
                   controller.destination != controller.defaultDestination {
                    Toggle("Utiliser cet emplacement pour les prochains imports", isOn: $controller.makeDestinationDefault)
                }
                LabeledContent("Dossier créé") {
                    Text(verbatim: controller.plannedFolder)
                        .lineLimit(2)
                }
            }
            .formStyle(.grouped)

            if !card.notImported.isEmpty {
                FileList(
                    title: "Ces fichiers ne seront pas copiés (format non pris en charge) :",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    lines: card.notImported.map { ($0, nil) }
                )
            }

            Text("Les fichiers sont copiés puis vérifiés un par un. Rien n'est modifié ni supprimé sur la carte.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: controller.close)
                    .keyboardShortcut(.cancelAction)
                Button("Importer", action: controller.startImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.destination == nil)
            }
        }
    }

    private var summary: String {
        var parts = [String(localized: "^[\(card.photoCount) photo](inflect: true)")]
        if card.videoCount > 0 {
            parts.append(String(localized: "^[\(card.videoCount) vidéo](inflect: true)"))
        }
        parts.append(card.totalBytes.formatted(.byteCount(style: .file)))
        if let first = card.earliestDate, let last = card.latestDate,
           !Calendar.current.isDate(first, inSameDayAs: last) {
            parts.append(String(localized: "du \(first.formatted(date: .abbreviated, time: .omitted)) au \(last.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// During the import: copy and check, then gallery creation. « Annuler » removes the copies.
private struct CardImportProgressView: View {
    @Environment(CardImportController.self) private var controller
    let card: CardContents
    let progress: CardImportProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import de la carte « \(card.name) »")
                .font(.title2.bold())
            ProgressView(value: progress?.fraction ?? 0)
            Group {
                if let progress, progress.phase == .indexing {
                    Text("Création de la galerie : \(progress.completedFiles) sur \(progress.totalFiles)")
                } else if let progress {
                    Text("Copie et vérification : \(min(progress.completedFiles + 1, progress.totalFiles)) sur \(progress.totalFiles)")
                    Text("\(progress.completedBytes.formatted(.byteCount(style: .file))) sur \(progress.totalBytes.formatted(.byteCount(style: .file)))\(progress.currentFile.map { " — \($0)" } ?? "")")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Préparation…")
                }
            }
            .monospacedDigit()
            Text("Annuler supprime les copies déjà faites. La carte n'est jamais modifiée.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: controller.cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// After the import: « Vous pouvez formater la carte » only when every copy is identical.
private struct CardImportReportView: View {
    @Environment(CardImportController.self) private var controller
    let report: CardImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if report.canFormatCard {
                Label("Import terminé", systemImage: "checkmark.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                Text("^[\(report.copiedFiles.count) fichier](inflect: true) copiés et vérifiés : chaque copie est identique à l'original (empreinte SHA-256).")
                Label("Vous pouvez formater la carte.", systemImage: "sdcard")
                    .font(.headline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Label("Import incomplet", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
                Text("Ne formatez pas la carte : tous ses fichiers ne sont pas copiés à l'identique.")
                    .font(.headline)
                if !report.copiedFiles.isEmpty {
                    Text("^[\(report.copiedFiles.count) fichier](inflect: true) copiés et vérifiés.")
                }
                if !report.failures.isEmpty {
                    FileList(
                        title: "Fichiers non copiés correctement :",
                        systemImage: "xmark.octagon.fill",
                        tint: .red,
                        lines: report.failures.map { ($0.relativePath, $0.reason.message) }
                    )
                }
                if !report.notImported.isEmpty {
                    FileList(
                        title: "Fichiers restés sur la carte (format non pris en charge) :",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        lines: report.notImported.map { ($0, nil) }
                    )
                }
            }
            if let indexingError = report.indexingError {
                Label("Les fichiers sont copiés, mais la galerie n'a pas pu être créée : \(indexingError)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            if !report.copiedFiles.isEmpty {
                LabeledContent("Rangés dans") {
                    Text(verbatim: report.sessionPath.replacingOccurrences(of: "/", with: " › "))
                }
            }
            HStack {
                if !report.copiedFiles.isEmpty {
                    Button("Afficher dans le Finder") { controller.revealInFinder(report) }
                }
                Spacer()
                Button("Terminé", action: controller.close)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// A titled, scrollable list of card files, with an optional reason under each.
private struct FileList: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let lines: [(path: String, detail: String?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: lines[index].path)
                                .font(.callout.monospaced())
                            if let detail = lines[index].detail {
                                Text(verbatim: detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
        }
    }
}
