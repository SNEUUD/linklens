import SwiftUI

/// Sidebar: the galleries, most recent first, with the indexing progress under the one being indexed.
struct GalleryListView: View {
    let galleries: [Gallery]
    @Binding var selection: UUID?
    let progress: IndexingProgress?
    let onCancel: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(galleries) { gallery in
                GalleryRow(
                    gallery: gallery,
                    progress: progress?.galleryId == gallery.id ? progress : nil,
                    onCancel: onCancel
                )
                .tag(gallery.id)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }
}

private struct GalleryRow: View {
    let gallery: Gallery
    let progress: IndexingProgress?
    let onCancel: () -> Void
    @Environment(GalleryAvailabilityMonitor.self) private var availabilityMonitor

    var body: some View {
        let availability = availabilityMonitor.availability(of: gallery.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(gallery.name)
                    .font(.headline)
                    .lineLimit(1)
                if !availability.canUseOriginals {
                    Image(systemName: availability.systemImage)
                        .foregroundStyle(.orange)
                        .help(availability.message ?? "")
                        .accessibilityLabel(availability.message ?? "")
                }
            }
            // `if let` unwraps an optional: the block only runs when `progress` is not nil
            // (like `if (progress != null)` in TypeScript, with `progress` typed non-null inside).
            if let progress {
                ProgressView(value: progress.fraction)
                HStack {
                    Text("Indexation : \(progress.completed) sur \(progress.total)")
                        .monospacedDigit()
                    Spacer()
                    Button("Annuler", action: onCancel)
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let message = availability.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if gallery.videoCount > 0 {
                Text("^[\(gallery.photoCount - gallery.videoCount) photo](inflect: true) · ^[\(gallery.videoCount) vidéo](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("^[\(gallery.photoCount) photo](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
