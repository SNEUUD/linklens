import AppKit
import SwiftData
import SwiftUI

/// The photos of a gallery, as a simple table (thumbnails come later), with the AI sorting (F3).
struct GalleryDetailView: View {
    let gallery: Gallery
    @Environment(CullingController.self) private var cullingController
    @Query private var photos: [Photo]
    @State private var revealError: String?

    init(gallery: Gallery) {
        self.gallery = gallery
        let galleryId = gallery.id
        // `@Query` is the live query of SwiftData (like a `useQuery` hook that re-renders on every save).
        // Its filter depends on the gallery, so it is built here rather than in the property declaration.
        _photos = Query(
            filter: #Predicate<Photo> { $0.gallery?.id == galleryId },
            sort: [SortDescriptor(\.captureDate), SortDescriptor(\.relativePath)]
        )
    }

    var body: some View {
        Table(photos) {
            TableColumn("Fichier", value: \.relativePath)
            TableColumn("Tri") { photo in
                VerdictBadge(verdict: photo.cullingVerdict)
            }
            .width(min: 90, ideal: 100)
            TableColumn("Raison") { photo in
                ReasonCell(photo: photo)
            }
            .width(min: 200, ideal: 340)
            TableColumn("Prise de vue") { photo in
                if let captureDate = photo.captureDate {
                    Text(captureDate, format: .dateTime.day().month().year().hour().minute().second())
                } else {
                    Text(verbatim: "—")
                }
            }
            TableColumn("Dimensions") { photo in
                Text(verbatim: photo.pixelWidth > 0 ? "\(photo.pixelWidth) × \(photo.pixelHeight)" : "—")
                    .monospacedDigit()
            }
            TableColumn("Taille") { photo in
                Text(photo.fileSize, format: .byteCount(style: .file))
                    .monospacedDigit()
            }
        }
        // `safeAreaInset` pins a bar above the table, which scrolls under it.
        .safeAreaInset(edge: .top, spacing: 0) {
            CullingStatusBar(gallery: gallery, photos: photos)
        }
        .navigationTitle(gallery.name)
        .navigationSubtitle(gallery.folderPath)
        .toolbar {
            Button(
                gallery.culledAt == nil ? "Trier les photos" : "Trier à nouveau",
                systemImage: "wand.and.stars"
            ) {
                cullingController.cull(galleryId: gallery.id)
            }
            .disabled(cullingController.isBusy(galleryId: gallery.id))
            .help("Proposer Garder, À revoir ou Rejeter pour chaque photo. Rien n'est supprimé.")
            Button("Afficher dans le Finder", systemImage: "folder", action: revealInFinder)
        }
        .alert(
            "Dossier inaccessible",
            isPresented: Binding(get: { revealError != nil }, set: { if !$0 { revealError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(revealError ?? "")
        }
    }

    /// Reopens the folder through its bookmark: also checks that access survives a restart.
    private func revealInFinder() {
        do {
            let folder = try FolderBookmark.resolve(gallery.folderBookmark)
            guard folder.startAccessingSecurityScopedResource() else {
                throw LibraryError.accessDenied(gallery.name)
            }
            defer { folder.stopAccessingSecurityScopedResource() }
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw LibraryError.folderNotFound(gallery.folderPath)
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            revealError = error.localizedDescription
        }
    }
}

/// Verdict as a coloured dot and a word (the word keeps it readable without colours and for VoiceOver).
private struct VerdictBadge: View {
    let verdict: CullingVerdict?

    var body: some View {
        if let verdict {
            Label {
                Text(verdict.label)
            } icon: {
                Circle()
                    .fill(verdict.color)
                    .frame(width: 8, height: 8)
            }
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pas encore triée")
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

/// Above the table: progress and "Annuler" while sorting, otherwise the number of photos per verdict.
private struct CullingStatusBar: View {
    let gallery: Gallery
    let photos: [Photo]
    @Environment(CullingController.self) private var cullingController

    var body: some View {
        if let progress = cullingController.progress, progress.galleryId == gallery.id {
            bar {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 240)
                Text("Tri des photos : \(progress.completed) sur \(progress.total)")
                    .monospacedDigit()
                Spacer()
                Button("Annuler") { cullingController.cancel(galleryId: gallery.id) }
            }
        } else if cullingController.isQueued(galleryId: gallery.id) {
            bar {
                ProgressView().controlSize(.small)
                Text("Tri en attente…")
                Spacer()
                Button("Annuler") { cullingController.cancel(galleryId: gallery.id) }
            }
        } else if gallery.culledAt != nil {
            bar {
                count(of: .keep)
                count(of: .review)
                count(of: .reject)
                Spacer()
                Text("Proposition de l'IA : rien n'est supprimé.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func count(of verdict: CullingVerdict) -> some View {
        let total = photos.filter { $0.cullingVerdict == verdict }.count
        return HStack(spacing: 6) {
            Circle().fill(verdict.color).frame(width: 8, height: 8)
            Text(verbatim: "\(verdict.label) : \(total)")
                .monospacedDigit()
        }
    }

    // `@ViewBuilder` lets a function take several views as content, like `children` in React.
    private func bar(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12, content: content)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
        }
        .background(.bar)
    }
}

extension CullingVerdict {
    var color: Color {
        switch self {
        case .keep: .green
        case .review: .orange
        case .reject: .red
        case .unknown: .gray
        }
    }
}
