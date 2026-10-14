import SwiftUI

/// The photos of a gallery as a table: file, verdict, reason, shot date, dimensions, size.
struct GalleryTableView: View {
    let photos: [Photo]
    // `@Bindable` gives two-way bindings (`$browser.selection`) to an `@Observable` object.
    @Bindable var browser: GalleryBrowser

    var body: some View {
        Table(photos, selection: $browser.selection) {
            // The table resizes every column together: the others are capped (`max`) so that
            // "Raison" takes the remaining space. The window minimum width is the sum of the `min`s.
            TableColumn("Fichier") { photo in
                Text(verbatim: photo.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(photo.relativePath)
            }
            .width(min: 115, ideal: 120, max: 160)
            TableColumn("Tri") { photo in
                VerdictBadge(verdict: photo.cullingVerdict)
            }
            .width(min: 80, ideal: 85, max: 100)
            TableColumn("Raison") { photo in
                ReasonCell(photo: photo)
            }
            .width(min: 220, ideal: 420)
            TableColumn("Prise de vue") { photo in
                if let captureDate = photo.captureDate {
                    // Numeric date ("21/09/2026 17:24:57"): short enough to keep every column visible.
                    Text(captureDate, format: .dateTime.day().month(.twoDigits).year().hour().minute().second())
                } else {
                    Text(verbatim: "—")
                }
            }
            .width(min: 140, ideal: 145, max: 150)
            TableColumn("Dimensions") { photo in
                Text(verbatim: photo.pixelWidth > 0 ? "\(photo.pixelWidth) × \(photo.pixelHeight)" : "—")
                    .monospacedDigit()
            }
            .width(min: 85, ideal: 90, max: 100)
            TableColumn("Taille") { photo in
                Text(photo.fileSize, format: .byteCount(style: .file))
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
