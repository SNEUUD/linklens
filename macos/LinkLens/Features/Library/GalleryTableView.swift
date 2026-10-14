import SwiftUI

/// The photos of a gallery as a table: file, verdict, burst, reason, shot date, dimensions, size.
/// A collapsed burst is one row (its best photo); the chevron of the "Rafale" column or S opens it (F4).
struct GalleryTableView: View {
    let rows: [DisplayedPhoto]
    // `@Bindable` gives two-way bindings (`$browser.selection`) to an `@Observable` object.
    @Bindable var browser: GalleryBrowser

    var body: some View {
        Table(rows, selection: $browser.selection) {
            // The table resizes every column together: the others are capped (`max`) so that
            // "Raison" takes the remaining space. The window minimum width is the sum of the `min`s.
            TableColumn("Fichier") { row in
                Text(verbatim: row.photo.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.photo.relativePath)
            }
            .width(min: 115, ideal: 120, max: 160)
            TableColumn("Tri") { row in
                VerdictBadge(verdict: row.photo.cullingVerdict)
            }
            .width(min: 80, ideal: 85, max: 100)
            TableColumn("Rafale") { row in
                if let burst = row.entry.burst {
                    BurstCell(burst: burst) { browser.toggleBurst(burst.number) }
                }
            }
            .width(min: 100, ideal: 110, max: 130)
            TableColumn("Raison") { row in
                ReasonCell(photo: row.photo)
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
        // No context menu yet: only the "primary action" (double-click or Return) opens the viewer.
        .contextMenu(forSelectionType: UUID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first { browser.openViewer(on: id) }
        }
        .onKeyPress(.space) {
            browser.openViewer() ? .handled : .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS"), phases: .down) { _ in
            browser.toggleSelectedBurst() ? .handled : .ignored
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

/// Main reason, a star for the best photo of a burst, and every reason in the tooltip.
private struct ReasonCell: View {
    let photo: Photo

    var body: some View {
        let messages = photo.cullingReasons.map { $0.message() }
        HStack(spacing: 4) {
            if photo.isBestOfBurst {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Meilleure photo de la rafale")
            }
            Text(verbatim: messages.first ?? "")
                .lineLimit(1)
                .foregroundStyle(photo.cullingVerdict == .keep ? .secondary : .primary)
        }
        .help(messages.joined(separator: "\n"))
    }
}
