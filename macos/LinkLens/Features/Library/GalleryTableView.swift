import SwiftUI

/// The photos of a gallery as a table: file, verdict, burst, reason, shot date, dimensions, size.
/// A collapsed burst is one row (its best photo); the chevron of the "Rafale" column or S opens it,
/// B chooses its best photo (F4).
/// P / U / X sort the selected photo by hand and go to the next row; A goes back to the AI's proposal.
struct GalleryTableView: View {
    let rows: [DisplayedPhoto]
    // `@Bindable` gives two-way bindings (`$browser.selection`) to an `@Observable` object.
    @Bindable var browser: GalleryBrowser
    let sorter: ManualSorter

    var body: some View {
        Table(rows, selection: $browser.selection) {
            // The table resizes every column together: the others are capped (`max`) so that
            // "Raison" takes the remaining space. The window minimum width is the sum of the `min`s.
            TableColumn("Fichier") { row in
                Text(verbatim: row.photo.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.photo.relativePath)
                    // VoiceOver lists these in the actions of the row's first cell.
                    .accessibilityActions {
                        SortingButtons { command in sorter.apply(command, to: [row.photo.id]) }
                        if let burst = row.entry.burst {
                            BurstCoverButtons(burst: burst) { command in sorter.apply(command, to: row.photo.id) }
                        }
                    }
            }
            .width(min: 115, ideal: 120, max: 160)
            TableColumn("Tri") { row in
                VerdictBadge(verdict: row.photo.verdict, isChosenByUser: row.photo.isVerdictChosenByUser)
                    .help(row.photo.verdictDescription ?? "")
            }
            .width(min: 80, ideal: 85, max: 100)
            TableColumn("Rafale") { row in
                if let burst = row.entry.burst {
                    BurstCell(burst: burst) { browser.toggleBurst(burst.number) }
                }
            }
            .width(min: 100, ideal: 110, max: 130)
            TableColumn("Raison") { row in
                ReasonCell(photo: row.photo, burst: row.entry.burst)
            }
            // 100 points less than before F4: the "Rafale" column keeps the window's minimum width unchanged.
            .width(min: 120, ideal: 330)
            TableColumn("Prise de vue") { row in
                if let captureDate = row.photo.captureDate {
                    // Numeric date ("21/09/2026 17:24:57"): short enough to keep every column visible.
                    Text(captureDate, format: .dateTime.day().month(.twoDigits).year().hour().minute().second())
                } else {
                    Text(verbatim: "—")
                }
            }
            .width(min: 140, ideal: 145, max: 150)
            TableColumn("Dimensions") { row in
                let photo = row.photo
                Text(verbatim: photo.pixelWidth > 0 ? "\(photo.pixelWidth) × \(photo.pixelHeight)" : "—")
                    .monospacedDigit()
            }
            .width(min: 85, ideal: 90, max: 100)
            TableColumn("Taille") { row in
                Text(row.photo.fileSize, format: .byteCount(style: .file))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 65, max: 75)
        }
        // Right-click: sort the clicked row by hand. Double-click or Return open the viewer.
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                SortingButtons(showsKeys: true) { command in sorter.apply(command, to: Array(ids)) }
                // The best photo of a burst: one row at a time.
                if ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }), let burst = row.entry.burst {
                    Divider()
                    BurstCoverButtons(burst: burst, showsKeys: true) { command in sorter.apply(command, to: row.photo.id) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { browser.openViewer(on: id) }
        }
        .onKeyPress(.space) {
            browser.openViewer() ? .handled : .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS"), phases: .down) { _ in
            browser.toggleSelectedBurst() ? .handled : .ignored
        }
        .onKeyPress(characters: SortingCommand.keyCharacters, phases: .down) { press in
            guard let command = SortingCommand(press) else { return .ignored }
            return sorter.applyToSelection(command, advance: true) ? .handled : .ignored
        }
        // B as in "best": the selected photo stands for its burst (F4), even after a new sorting.
        .onKeyPress(characters: BurstCoverCommand.keyCharacters, phases: .down) { press in
            guard BurstCoverCommand(press) != nil else { return .ignored }
            return sorter.chooseSelectedBurstCover() ? .handled : .ignored
        }
    }
}

/// Burst of a row, with a chevron like a Finder folder: "▸ 3 · 5 photos" closed, "▾ 3" open.
private struct BurstCell: View {
    let burst: BurstPlacement
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: burst.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                if burst.isExpanded {
                    Text(verbatim: "\(burst.number)")
                } else {
                    Text("\(burst.number) · \(burst.count) photos")
                }
            }
            .monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(burst.isExpanded ? "Replier la rafale (S)" : "Voir toutes les photos de la rafale (S)")
        .accessibilityLabel(burst.isExpanded ? "Replier la rafale \(burst.number)" : "Voir toute la rafale \(burst.number)")
    }
}

/// Main reason of the AI, a star for the best photo of a burst, and every reason in the tooltip.
/// When the user overruled the AI, the reason says what the AI proposed: « IA : Rejeter · Photo floue ».
private struct ReasonCell: View {
    let photo: Photo
    let burst: BurstPlacement?

    var body: some View {
        let messages = photo.cullingReasons.map { $0.message() }
        let overruled = photo.isVerdictChosenByUser && photo.cullingVerdict != nil && photo.cullingVerdict != photo.verdict
        HStack(spacing: 4) {
            if let burst, burst.showsStar(isBestOfBurst: photo.isBestOfBurst) {
                // The user's choice is an outlined star, like their verdicts.
                Image(systemName: burst.isCoverChosenByUser ? "star.circle.fill" : "star.fill")
                    .foregroundStyle(.yellow)
                    .help(burst.starDescription)
                    .accessibilityLabel(Text(verbatim: burst.starDescription))
            }
            if overruled, let proposal = photo.cullingVerdict {
                Text("IA : \(proposal.label) ·")
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: messages.first ?? "")
                .lineLimit(1)
                .foregroundStyle(photo.verdict == .keep || overruled ? .secondary : .primary)
        }
        .help(messages.joined(separator: "\n"))
    }
}
