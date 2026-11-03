import SwiftUI

/// Which photos and videos of the gallery are exported.
enum ExportScope: String, CaseIterable, Identifiable {
    /// Default: the photos sorted « Garder » (by the user, otherwise by the AI), « À revoir » excluded,
    /// and the videos. The AI does not sort videos: all go with them, except those the user rejected (X).
    case keep
    case all
    case selection

    var id: Self { self }

    /// "Garder" when the gallery has photos to keep, otherwise everything.
    static func defaultScope(for photos: [Photo]) -> ExportScope {
        hasPhotosToKeep(photos) ? .keep : .all
    }

    static func hasPhotosToKeep(_ photos: [Photo]) -> Bool {
        photos.contains { $0.mediaKind != .video && $0.verdict == .keep }
    }

    /// Photos and videos of this scope, in the order of `photos`.
    func photos(from photos: [Photo], selectedPhotoId: UUID?) -> [Photo] {
        switch self {
        case .keep: photos.filter(Self.isExportedWithThePhotosToKeep)
        case .all: photos
        case .selection: photos.filter { $0.id == selectedPhotoId }
        }
    }

    private static func isExportedWithThePhotosToKeep(_ photo: Photo) -> Bool {
        photo.mediaKind == .video ? photo.userVerdict != .reject : photo.verdict == .keep
    }
}

/// How many photos and videos a scope holds, for its label.
struct ExportCounts: Equatable {
    var photos: Int
    var videos: Int

    init(photos: Int, videos: Int) {
        self.photos = photos
        self.videos = videos
    }

    init(_ photos: [Photo]) {
        videos = photos.count { $0.mediaKind == .video }
        self.photos = photos.count - videos
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
    // Remembered like the photo format (`@AppStorage` is `localStorage` that redraws the view).
    @AppStorage("exportVideoPreset") private var videoPreset = VideoExportPreset.compatible
    @AppStorage("exportSkipsVideos") private var skipsVideos = false
    @State private var scope: ExportScope

    init(gallery: Gallery, photos: [Photo], selectedPhotoId: UUID?) {
        self.gallery = gallery
        self.photos = photos
        self.selectedPhotoId = selectedPhotoId
        // `_scope` is the `@State` storage itself: setting its first value here, like `useState(initial)`.
        _scope = State(initialValue: ExportScope.defaultScope(for: photos))
    }

    var body: some View {
        // Read once per update: the counts below come from this list, not from new passes over `photos`.
        let inScope = scope.photos(from: photos, selectedPhotoId: selectedPhotoId)
        let hasVideos = inScope.contains { $0.mediaKind == .video }
        VStack(alignment: .leading, spacing: 20) {
            (hasVideos ? Text("Exporter des photos et des vidéos") : Text("Exporter des photos"))
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                (galleryHasVideos ? Text("À exporter") : Text("Photos"))
                    .font(.headline)
                Picker("À exporter", selection: $scope) {
                    ForEach(availableScopes) { scope in
                        Text(label(for: scope)).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if scope == .keep, hasVideos {
                    Text("Les vidéos ne sont pas triées par l'IA : elles partent avec les photos à garder, sauf celles que vous avez rejetées.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                (hasVideos ? Text("Format des photos") : Text("Format"))
                    .font(.headline)
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(ExportPreset.allCases) { candidate in
                        PresetCard(
                            title: candidate.title, purpose: candidate.purpose, details: candidate.details,
                            systemImage: candidate.systemImage, isSelected: candidate == preset
                        ) {
                            preset = candidate
                        }
                    }
                }
            }

            // Only when the chosen photos include videos (from an SD card, F1).
            if hasVideos {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Format des vidéos")
                        .font(.headline)
                    LazyVGrid(columns: Self.columns, spacing: 12) {
                        ForEach(VideoExportPreset.allCases) { candidate in
                            PresetCard(
                                title: candidate.title, purpose: candidate.purpose, details: candidate.details,
                                systemImage: candidate.systemImage, isSelected: !skipsVideos && candidate == videoPreset
                            ) {
                                videoPreset = candidate
                            }
                        }
                    }
                    .disabled(skipsVideos)
                    .opacity(skipsVideos ? 0.5 : 1)
                    Toggle("Ne pas exporter les vidéos", isOn: $skipsVideos)
                        .toggleStyle(.checkbox)
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
                Button("Choisir le dossier…") { export(inScope) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items(inScope).isEmpty || !availabilityMonitor.availability(of: gallery.id).canUseOriginals)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private static let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    /// What is sent to the export: the scope, without its videos when « Ne pas exporter les vidéos » is ticked.
    private func items(_ inScope: [Photo]) -> [ExportItem] {
        let kept = skipsVideos ? inScope.filter { $0.mediaKind != .video } : inScope
        return kept.map(\.exportItem)
    }

    private var galleryHasVideos: Bool {
        photos.contains { $0.mediaKind == .video }
    }

    private var availableScopes: [ExportScope] {
        ExportScope.allCases.filter { scope in
            switch scope {
            case .keep: ExportScope.hasPhotosToKeep(photos)
            case .all: true
            case .selection: selectedPhotoId.map { id in photos.contains { $0.id == id } } ?? false
            }
        }
    }

    private func label(for scope: ExportScope) -> String {
        let counts = ExportCounts(scope.photos(from: photos, selectedPhotoId: selectedPhotoId))
        return Self.label(for: scope, counts: counts, selected: photos.first { $0.id == selectedPhotoId })
    }

    /// « Les photos à garder (12) et les vidéos (3) », « Toutes (52 photos, 3 vidéos) ». Without videos,
    /// the labels stay as before videos existed.
    static func label(for scope: ExportScope, counts: ExportCounts, selected: Photo?) -> String {
        switch scope {
        case .keep:
            if counts.videos == 0 {
                return String(localized: "Les photos à garder (\(counts.photos))")
            }
            return String(localized: "Les photos à garder (\(counts.photos)) et les vidéos (\(counts.videos))")
        case .all:
            if counts.videos == 0 {
                return String(localized: "Toutes les photos (\(counts.photos))")
            }
            return String(inflecting: "Toutes (^[\(counts.photos) photo](inflect: true), ^[\(counts.videos) vidéo](inflect: true))")
        case .selection:
            let name = selected.map { ($0.relativePath as NSString).lastPathComponent } ?? ""
            if selected?.mediaKind == .video {
                return String(localized: "La vidéo sélectionnée (\(name))")
            }
            return String(localized: "La photo sélectionnée (\(name))")
        }
    }

    private func export(_ inScope: [Photo]) {
        let items = items(inScope)
        let preset = preset
        let videoPreset = videoPreset
        let gallery = gallery
        let exportController = exportController
        dismiss()
        // The folder picker opens once the sheet is gone (a `Task` runs on the next turn of the main loop).
        Task {
            exportController.chooseDestinationAndExport(items, of: gallery, preset: preset, videoPreset: videoPreset)
        }
    }
}

/// One format, as a large selectable card (photo or video).
private struct PresetCard: View {
    let title: LocalizedStringResource
    let purpose: LocalizedStringResource
    /// Technical values, shown only as a tooltip.
    let details: LocalizedStringResource
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 28)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(purpose)
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
        .help(Text(details))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
