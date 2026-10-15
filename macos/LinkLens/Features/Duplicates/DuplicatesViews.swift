import CoreGraphics
import SwiftUI

/// "Doublons": identical files across every gallery, the space they take, the copy kept in each group
/// and, after confirmation, the others moved to the trash. Nothing is moved without the user.
struct DuplicatesSheet: View {
    @Environment(DuplicatesController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Doublons")
                    .font(.title2.bold())
                Text("Fichiers identiques octet par octet, dans toutes vos galeries. Choisissez la copie à garder : les autres vont dans la corbeille, rien n'est effacé définitivement.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if controller.notice != nil || !controller.skippedFiles.isEmpty {
                Divider()
                NoticeBar()
            }
            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 540, idealHeight: 640)
        // `.task` runs when the sheet appears (like a `useEffect` with no dependency).
        .task { controller.scan() }
        .onDisappear { controller.cancelScan() }
        .confirmationDialog(
            String(localized: "Mettre ^[\(controller.selectedCopyCount) copie](inflect: true) à la corbeille ?"),
            isPresented: $isConfirming
        ) {
            Button("Mettre à la corbeille", role: .destructive, action: controller.moveSelectionToTrash)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(controller.selectedBytes.formatted(.byteCount(style: .file))) seront libérés quand vous viderez la corbeille. Les copies gardées ne sont pas modifiées, et vous pourrez annuler.")
        }
        .alert(
            "Doublons",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let progress = controller.progress {
            VStack(spacing: 12) {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 320)
                Text("Comparaison des fichiers : \(progress.completedFiles) sur \(progress.totalFiles)")
                    .monospacedDigit()
                Button("Annuler", action: controller.cancelScan)
            }
        } else if controller.isScanning || controller.isMovingFiles {
            ProgressView()
        } else if let report = controller.report {
            if report.groups.isEmpty {
                ContentUnavailableView {
                    Label("Aucun doublon", systemImage: "checkmark.circle")
                } description: {
                    Text("Aucun fichier n'existe en plusieurs exemplaires dans vos galeries.")
                }
            } else {
                List {
                    ReportWarnings(report: report)
                    ForEach(report.groups) { group in
                        DuplicateGroupRow(group: group)
                    }
                }
            }
        } else {
            Button("Rechercher les doublons", action: controller.scan)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if let report = controller.report, !report.groups.isEmpty, !controller.isScanning {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Espace récupérable : \(report.recoverableBytes.formatted(.byteCount(style: .file)))")
                        .font(.headline)
                        .monospacedDigit()
                    Text("^[\(report.groups.count) fichier](inflect: true) en plusieurs exemplaires")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Fermer") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Mettre ^[\(controller.selectedCopyCount) copie](inflect: true) à la corbeille…")) {
                isConfirming = true
            }
            .disabled(controller.selectedCopyCount == 0 || controller.isScanning || controller.isMovingFiles)
        }
    }
}

/// After a deletion or an undo: what happened, "Annuler", and the files left in place.
private struct NoticeBar: View {
    @Environment(DuplicatesController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let notice = controller.notice {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                    Text(notice)
                }
                Spacer()
                if controller.lastTrash != nil {
                    Button("Annuler la mise à la corbeille", action: controller.undoLastTrash)
                        .keyboardShortcut("z")
                        .disabled(controller.isMovingFiles || controller.isScanning)
                }
                Button("Masquer", action: controller.dismissNotice)
                    .buttonStyle(.borderless)
            }
            if !controller.skippedFiles.isEmpty {
                DisclosureGroup(String(localized: "^[\(controller.skippedFiles.count) fichier](inflect: true) laissé en place")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(controller.skippedFiles.enumerated()), id: \.offset) { _, file in
                            Text(verbatim: "\(file.galleryName) › \(file.relativePath) : \(file.reason.message)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Galleries that could not be checked (disk unplugged…) and unreadable files.
private struct ReportWarnings: View {
    let report: DuplicateReport

    var body: some View {
        if !report.unreachableGalleries.isEmpty {
            Label(
                "Galeries hors d'atteinte, non vérifiées : \(report.unreachableGalleries.formatted(.list(type: .and)))",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .foregroundStyle(.secondary)
        }
        if report.unreadableFiles > 0 {
            Label("^[\(report.unreadableFiles) fichier](inflect: true) illisible, ignoré", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}

/// One group: a thumbnail, then every copy with the choice of the one to keep.
private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @Environment(DuplicatesController.self) private var controller

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(
                "Traiter ce groupe",
                isOn: Binding(get: { controller.isIncluded(group) }, set: { controller.setIncluded($0, group) })
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Décocher pour laisser toutes les copies de ce fichier en place")

            DuplicateThumbnail(photoIds: group.copies.map(\.photoId))

            VStack(alignment: .leading, spacing: 6) {
                Text(group.copies[0].fileName)
                    .font(.headline)
                Text("^[\(group.copies.count) copie](inflect: true) identique · \(group.fileSize.formatted(.byteCount(style: .file))) chacune")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ForEach(group.copies) { copy in
                    CopyRow(group: group, copy: copy)
                }
                // F9: the kept copy must be read again before the others move.
                if let kept = group.copies.first(where: { $0.photoId == controller.keptPhotoId(in: group) }),
                   let message = controller.availability(of: kept).message {
                    Label("Copie gardée hors d'atteinte (\(message)) : rien ne sera déplacé dans ce groupe.", systemImage: "externaldrive.badge.xmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .opacity(controller.isIncluded(group) ? 1 : 0.5)
        }
        .padding(.vertical, 6)
    }
}

/// A copy: a radio button "garder", where it is, and what will happen to it.
private struct CopyRow: View {
    let group: DuplicateGroup
    let copy: DuplicateCopy
    @Environment(DuplicatesController.self) private var controller

    var body: some View {
        let isKept = controller.keptPhotoId(in: group) == copy.photoId
        let isIncluded = controller.isIncluded(group)
        Button {
            controller.keep(copy.photoId, in: group)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isKept ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isKept ? Color.accentColor : .secondary)
                Text(copy.galleryName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(copy.relativePath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if isKept {
                    Text(controller.keepsProposal(in: group) ? "Gardée · \(group.proposal.reason.label)" : "Gardée · votre choix")
                        .foregroundStyle(.green)
                } else if let message = controller.availability(of: copy).message {
                    // F9: nothing on an unplugged disk is moved.
                    Label("Laissée en place · \(message)", systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.orange)
                        .help(controller.availability(of: copy).help(for: .trash) ?? "")
                } else if isIncluded {
                    Label("Corbeille", systemImage: "trash")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Laissée en place")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .help("Garder cette copie")
        // VoiceOver reads the row as one radio button: "Mariage, DSC00001.ARW, sélectionné".
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isKept ? [.isSelected] : [])
    }
}

/// The cached thumbnail of any copy of the group (they are the same picture).
private struct DuplicateThumbnail: View {
    let photoIds: [UUID]
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 72)
        .task(id: photoIds) { image = await Self.load(photoIds) }
    }

    @concurrent
    private nonisolated static func load(_ photoIds: [UUID]) async -> CGImage? {
        for photoId in photoIds {
            if let image = ThumbnailCache.standard.image(for: photoId) { return image }
        }
        return nil
    }
}
