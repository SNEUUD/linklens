import SwiftUI

/// The card import window: reading the card, settings, then progress, then the report.
struct CardImportSheet: View {
    @Environment(CardImportController.self) private var controller

    var body: some View {
        Group {
            switch controller.stage {
            case .idle:
                EmptyView()
            case .scanning(let cardName):
                CardImportHeader(
                    systemImage: "sdcard",
                    tint: Palette.accent,
                    soft: Palette.accentSoft,
                    title: Text("Lecture de la carte « \(cardName) »…"),
                    subtitle: Text("Liste des photos et des vidéos. Rien n'est modifié sur la carte.")
                ) {
                    ProgressView()
                        .controlSize(.small)
                }
            case .ready(let card):
                CardImportForm(card: card)
            case .importing(let card):
                CardImportProgressView(card: card, progress: controller.progress)
            case .finished(let report):
                CardImportReportView(report: report)
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(controller.isImporting)
    }
}

/// Before the import: what the card holds, the session name, the location and the folder created.
private struct CardImportForm: View {
    @Environment(CardImportController.self) private var controller
    let card: CardContents
    /// `@FocusState` tracks which field has the keyboard, like a `ref.current.focus()` you can also read.
    @FocusState private var isNameFocused: Bool

    var body: some View {
        // `@Bindable` gives two-way bindings (`$controller.sessionName`) to an `@Observable` object.
        @Bindable var controller = controller
        let summary = CardImportSummary(card: card)

        VStack(alignment: .leading, spacing: 20) {
            CardImportHeader(
                systemImage: "sdcard",
                tint: Palette.accent,
                soft: Palette.accentSoft,
                title: Text("Importer la carte « \(card.name) »"),
                subtitle: Text(verbatim: summary.line())
            )

            if let notice = controller.notice {
                Label(notice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            CardPreviewStrip(card: card, summary: summary)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nom de la séance")
                            .fontWeight(.semibold)
                            .accessibilityHidden(true)
                        TextField("Nom de la séance", text: $controller.sessionName, prompt: Text("Ex. : Mariage Julie & Tom"))
                            .textFieldStyle(.plain)
                            .focused($isNameFocused)
                            .fieldBox(isFocused: isNameFocused)
                            .accessibilityLabel("Nom de la séance")
                    }
                    // Not in the mockup: the card's first day is chosen, but a session can go past midnight.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Date")
                            .fontWeight(.semibold)
                            .accessibilityHidden(true)
                        DatePicker("Date de la séance", selection: $controller.sessionDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            // The picker is taller than a line of text: the box is a little tighter.
                            .padding(.vertical, -3)
                            .fieldBox()
                            .accessibilityLabel("Date de la séance")
                    }
                    .fixedSize()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Emplacement")
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(Palette.accent.color)
                            .accessibilityHidden(true)
                        if let destination = controller.destination {
                            Text(verbatim: destination.shortDisplayPath)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(destination.displayPath)
                                .accessibilityLabel(Text("Emplacement : \(destination.shortDisplayPath)"))
                        } else {
                            Text("Aucun emplacement choisi")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Emplacement : aucun emplacement choisi")
                        }
                        Spacer(minLength: 10)
                        Button(controller.destination == nil ? "Choisir…" : "Changer…", action: controller.chooseDestination)
                            .buttonStyle(.capsule(.secondary, size: .small))
                            .accessibilityLabel(controller.destination == nil ? "Choisir l'emplacement…" : "Changer l'emplacement…")
                    }
                    .fieldBox()
                    // « 2026 / 2026-09-20 Mariage Julie & Tom / », follows the name as it is typed.
                    Text(verbatim: controller.plannedFolder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 2)
                        .accessibilityLabel(ImportPathPreview.spokenText(date: controller.sessionDate, sessionName: controller.sessionName))
                }

                if controller.destination != nil, controller.defaultDestination != nil,
                   controller.destination != controller.defaultDestination {
                    Toggle("Utiliser cet emplacement pour les prochains imports", isOn: $controller.makeDestinationDefault)
                        .toggleStyle(.checkbox)
                }
                Toggle("Trier les photos dès la fin de l'import", isOn: $controller.sortsAfterImport)
                    .toggleStyle(.checkbox)
            }

            if !card.notImported.isEmpty {
                FileList(
                    title: "Ces fichiers ne seront pas copiés (format non pris en charge) :",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Palette.review.color,
                    lines: card.notImported.map { ($0, nil) }
                )
            }

            MessageBox(systemImage: "checkmark.shield", tint: Palette.keep, soft: Palette.keepSoft) {
                Text("Chaque copie est comparée à l'original. LinkLens ne vous propose de formater la carte que si tout est identique. La carte n'est jamais modifiée.")
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Annuler", role: .cancel, action: controller.close)
                    .buttonStyle(.capsule(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(action: controller.startImport) {
                    Text("Importer ^[\(summary.fileCount) fichier](inflect: true)")
                }
                .buttonStyle(.capsule(.prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(controller.destination == nil)
                .help(controller.destination == nil ? "Choisissez d'abord un emplacement" : "")
            }
        }
        .onAppear { isNameFocused = true }
    }
}

/// During the import: copy and check, then gallery creation. « Annuler » removes the copies.
private struct CardImportProgressView: View {
    @Environment(CardImportController.self) private var controller
    let card: CardContents
    let progress: CardImportProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CardImportHeader(
                systemImage: "sdcard",
                tint: Palette.accent,
                soft: Palette.accentSoft,
                title: Text("Import de la carte « \(card.name) »"),
                subtitle: stepText
            )

            CardPreviewStrip(card: card, summary: CardImportSummary(card: card))

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress?.fraction ?? 0)
                    .tint(Palette.accent.color)
                    .accessibilityLabel("Progression de l'import")
                if let progress, progress.phase == .copying {
                    Text(verbatim: "\(progress.completedBytes.formatted(.byteCount(style: .file))) / \(progress.totalBytes.formatted(.byteCount(style: .file)))\(progress.currentFile.map { " — \($0)" } ?? "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            MessageBox(systemImage: "info.circle", tint: nil, soft: Palette.field) {
                Text("Annuler supprime les copies déjà faites. La carte n'est jamais modifiée.")
            }

            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: controller.cancel)
                    .buttonStyle(.capsule(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var stepText: Text {
        guard let progress else { return Text("Préparation…") }
        switch progress.phase {
        case .indexing:
            return Text("Création de la galerie : \(progress.completedFiles) sur \(progress.totalFiles)")
        case .copying:
            return Text("Copie et vérification : \(min(progress.completedFiles + 1, progress.totalFiles)) sur \(progress.totalFiles)")
        }
    }
}

/// After the import: « Vous pouvez formater la carte » only when every copy is identical.
private struct CardImportReportView: View {
    @Environment(CardImportController.self) private var controller
    let report: CardImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if report.canFormatCard {
                CardImportHeader(
                    systemImage: "checkmark.shield",
                    tint: Palette.keep,
                    soft: Palette.keepSoft,
                    title: Text("Import terminé"),
                    subtitle: Text("^[\(report.copiedFiles.count) fichier](inflect: true) copiés et vérifiés depuis la carte « \(report.cardName) »")
                )
                MessageBox(systemImage: "sdcard", tint: Palette.keep, soft: Palette.keepSoft, isProminent: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vous pouvez formater la carte.")
                            .font(.system(size: 15, weight: .bold))
                        Text("Chaque copie est identique à l'original (empreinte SHA-256).")
                    }
                }
            } else {
                CardImportHeader(
                    systemImage: "exclamationmark.triangle",
                    tint: Palette.review,
                    soft: Palette.reviewSoft,
                    title: Text("Import incomplet"),
                    subtitle: report.copiedFiles.isEmpty
                        ? Text("Aucun fichier copié")
                        : Text("^[\(report.copiedFiles.count) fichier](inflect: true) copiés et vérifiés")
                )
                MessageBox(systemImage: "sdcard", tint: Palette.review, soft: Palette.reviewSoft, isProminent: true) {
                    Text("Ne formatez pas la carte : tous ses fichiers ne sont pas copiés à l'identique.")
                        .font(.system(size: 15, weight: .bold))
                }
                if !report.failures.isEmpty {
                    FileList(
                        title: "Fichiers non copiés correctement :",
                        systemImage: "xmark.octagon.fill",
                        tint: Palette.reject.color,
                        lines: report.failures.map { ($0.relativePath, $0.reason.message) }
                    )
                }
                if !report.notImported.isEmpty {
                    FileList(
                        title: "Fichiers restés sur la carte (format non pris en charge) :",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Palette.review.color,
                        lines: report.notImported.map { ($0, nil) }
                    )
                }
            }

            if let indexingError = report.indexingError {
                Label("Les fichiers sont copiés, mais la galerie n'a pas pu être créée : \(indexingError)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }

            if !report.copiedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rangés dans")
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(Palette.accent.color)
                            .accessibilityHidden(true)
                        Text(verbatim: report.sessionPath.split(separator: "/").joined(separator: " / ") + " /")
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .fieldBox()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Rangés dans \(report.sessionPath.replacingOccurrences(of: "/", with: ", puis "))"))
                    if report.galleryId != nil && controller.sortsAfterImport {
                        Text("La galerie est ouverte et l'IA commence le tri.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                if !report.copiedFiles.isEmpty {
                    Button("Afficher dans le Finder") { controller.revealInFinder(report) }
                        .buttonStyle(.capsule(.secondary))
                }
                Spacer()
                Button("Terminé", action: controller.close)
                    .buttonStyle(.capsule(.prominent))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Parts

/// Icon in a tinted rounded square, title and one line under it, as at the top of the mockup.
private struct CardImportHeader<Accessory: View>: View {
    let systemImage: String
    let tint: AdaptiveColor
    let soft: AdaptiveColor
    let title: Text
    let subtitle: Text
    /// Something at the end of the title line (a spinner while the card is read).
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(tint.color)
                .frame(width: 44, height: 44)
                .background(soft.color, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.system(size: 17, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h1)
                subtitle
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension CardImportHeader where Accessory == EmptyView {
    init(systemImage: String, tint: AdaptiveColor, soft: AdaptiveColor, title: Text, subtitle: Text) {
        self.init(systemImage: systemImage, tint: tint, soft: soft, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A few photos of the card, from the previews the camera embeds in them (read-only), then « +N ».
private struct CardPreviewStrip: View {
    let card: CardContents
    let summary: CardImportSummary
    @State private var images: [String: CGImage] = [:]

    private static let tileSize = CGSize(width: 58, height: 87)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(summary.previewFiles, id: \.relativePath) { file in
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Palette.field.color)
                    if let image = images[file.relativePath] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if summary.hiddenCount > 0 {
                Text(verbatim: "+\(summary.hiddenCount)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                    .background(Palette.field.color, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aperçu de la carte : \(summary.previewFiles.count) photos montrées sur \(summary.fileCount) fichiers"))
        // One photo at a time, so the strip fills in from the left without waiting for the slowest.
        .task(id: card.root) {
            for file in summary.previewFiles where images[file.relativePath] == nil {
                if let image = await Self.loadPreview(of: file.url, card: card.root) {
                    images[file.relativePath] = image
                }
            }
        }
    }

    /// The preview embedded in the photo, away from the main thread. Only reads the file.
    @concurrent
    private static func loadPreview(of url: URL, card: URL) async -> CGImage? {
        let isAccessing = card.startAccessingSecurityScopedResource()
        defer { if isAccessing { card.stopAccessingSecurityScopedResource() } }
        return try? ThumbnailGenerator.makeThumbnail(from: url, maxPixelSize: 200)
    }
}

/// A rounded tinted box with an icon and a message (the green « shield » of the mockup).
private struct MessageBox<Content: View>: View {
    let systemImage: String
    /// Nil: the icon takes the text colour.
    let tint: AdaptiveColor?
    let soft: AdaptiveColor
    var isProminent = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: isProminent ? 20 : 15))
                .foregroundStyle(tint.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                .frame(width: isProminent ? 26 : 18)
                .accessibilityHidden(true)
            content
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(isProminent ? 14 : 12)
        .background(soft.color, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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
            .frame(maxHeight: 120)
        }
    }
}

private extension View {
    /// The look of the mockup's fields: pale fill, thin line, and an accent halo while typing.
    func fieldBox(isFocused: Bool = false) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Palette.field.color, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line.color, lineWidth: 1))
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.accentSoft.color, lineWidth: 3)
                        .padding(-1.5)
                }
            }
    }
}
