import SwiftUI

/// Which photos of the gallery are exported.
enum ExportScope: String, CaseIterable, Identifiable {
    /// Default: the photos sorted « Garder » (by the user, otherwise by the AI). « À revoir » is not included.
    case keep
    case all
    case selection

    var id: Self { self }

    /// "Garder" when the gallery has such photos, otherwise everything.
    static func defaultScope(for photos: [Photo]) -> ExportScope {
        photos.contains { $0.verdict == .keep } ? .keep : .all
    }

    func photos(from photos: [Photo], selectedPhotoId: UUID?) -> [Photo] {
        switch self {
        case .keep: photos.filter { $0.verdict == .keep }
        case .all: photos
        case .selection: photos.filter { $0.id == selectedPhotoId }
        }
    }
}

extension Photo {
    var exportItem: ExportItem {
        ExportItem(photoId: id, relativePath: relativePath)
    }
}

/// "Exporter des photos": which photos, then one of the four formats. No technical setting is shown;
/// the details of a format appear only as a tooltip.
struct ExportSheet: View {
    let gallery: Gallery
    /// In display order (by date).
    let photos: [Photo]
    let selectedPhotoId: UUID?
    @Environment(ExportController.self) private var exportController
    @Environment(GalleryAvailabilityMonitor.self) private var availabilityMonitor
    // `dismiss` closes the sheet that shows this view (like calling `onClose` passed by a parent modal).
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportPreset") private var preset = ExportPreset.webJPEG
    @State private var scope: ExportScope

    init(gallery: Gallery, photos: [Photo], selectedPhotoId: UUID?) {
        self.gallery = gallery
        self.photos = photos
        self.selectedPhotoId = selectedPhotoId
        // `_scope` is the `@State` storage itself: setting its first value here, like `useState(initial)`.
        _scope = State(initialValue: ExportScope.defaultScope(for: photos))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Exporter des photos")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Photos")
                    .font(.headline)
                Picker("Photos", selection: $scope) {
                    ForEach(availableScopes) { scope in
                        Text(label(for: scope)).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Format")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(ExportPreset.allCases) { candidate in
                        PresetCard(preset: candidate, isSelected: candidate == preset) {
                            preset = candidate
                        }
                    }
                }
            }

            // The disk can be unplugged while the sheet is open (F9).
            let availability = availabilityMonitor.availability(of: gallery.id)
            if let help = availability.help(for: .export) {
                Label(help, systemImage: availability.systemImage)
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("Les originaux ne sont jamais modifiés.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choisir le dossier…", action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || !availabilityMonitor.availability(of: gallery.id).canUseOriginals)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var items: [ExportItem] {
        scope.photos(from: photos, selectedPhotoId: selectedPhotoId).map(\.exportItem)
    }

    private var availableScopes: [ExportScope] {
        ExportScope.allCases.filter { scope in
            switch scope {
            case .keep: photos.contains { $0.verdict == .keep }
            case .all: true
            case .selection: selectedPhotoId.map { id in photos.contains { $0.id == id } } ?? false
            }
        }
    }

    private func label(for scope: ExportScope) -> String {
        let count = scope.photos(from: photos, selectedPhotoId: selectedPhotoId).count
        switch scope {
        case .keep:
            return String(localized: "Les photos à garder (\(count))")
        case .all:
            return String(localized: "Toutes les photos (\(count))")
        case .selection:
            let name = photos.first { $0.id == selectedPhotoId }.map { ($0.relativePath as NSString).lastPathComponent } ?? ""
            return String(localized: "La photo sélectionnée (\(name))")
        }
    }

    private func export() {
        let items = items
        let preset = preset
        let gallery = gallery
        let exportController = exportController
        dismiss()
        // The folder picker opens once the sheet is gone (a `Task` runs on the next turn of the main loop).
        Task {
            exportController.chooseDestinationAndExport(items, of: gallery, preset: preset)
        }
    }
}

/// One format, as a large selectable card.
private struct PresetCard: View {
    let preset: ExportPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: preset.systemImage)
                    .font(.title2)
                    .frame(width: 28)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.title)
                        .font(.headline)
                    Text(preset.purpose)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(Text(preset.details))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Below the photos: progress and "Annuler" while exporting, then the result.
struct ExportStatusBar: View {
    let galleryId: UUID
    @Environment(ExportController.self) private var exportController

    var body: some View {
        if let progress = exportController.progress, progress.galleryId == galleryId {
            bar {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 240)
                Text("Export en \(String(localized: progress.preset.title)) : \(progress.completed) sur \(progress.total)")
                    .monospacedDigit()
                Spacer()
                Button("Annuler", action: exportController.cancel)
            }
        } else if let summary = exportController.summary, summary.galleryId == galleryId {
            bar {
                let isComplete = summary.failures.isEmpty && !summary.wasCancelled
                Image(systemName: isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isComplete ? .green : .orange)
                Text("Photos exportées : \(summary.exportedFiles.count), dans « \(summary.destination.lastPathComponent) »")
                    .monospacedDigit()
                if summary.wasCancelled {
                    Text("Export annulé")
                        .foregroundStyle(.secondary)
                }
                if !summary.failures.isEmpty {
                    Text("Échecs : \(summary.failures.count)")
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .help(summary.failures.map(\.message).joined(separator: "\n"))
                }
                Spacer()
                if !summary.exportedFiles.isEmpty {
                    Button("Afficher dans le Finder", action: exportController.revealExportedFiles)
                }
                Button("Fermer", action: exportController.dismissSummary)
            }
        }
    }

    private func bar(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12, content: content)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
