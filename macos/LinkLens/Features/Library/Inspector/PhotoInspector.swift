import SwiftUI

/// The inspector on the right of the photos, as in the mockup: name and date, preview with the subject
/// Vision found, Garder / À revoir / Rejeter, « Pourquoi ce choix » and « Infos ».
///
/// Everything comes from the catalogue (and the cached thumbnail): with the disk unplugged (F9), the
/// inspector shows the same things.
struct PhotoInspector: View {
    /// The selected photo (the cover of a collapsed burst), nil when nothing is selected.
    let photo: Photo?
    /// Every photo of its burst, itself included; empty outside a burst.
    let burstMembers: [Photo]
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    /// Garder / À revoir / Rejeter / back to the AI, through the gallery's `ManualSorter` (with undo).
    let onSort: (SortingCommand) -> Void

    var body: some View {
        if let photo {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorHeader(photo: photo)
                    InspectorPreview(photo: photo, loader: loader, canUseOriginals: canUseOriginals)
                    VerdictPicker(photo: photo, onSort: onSort)
                    if photo.mediaKind != .video, photo.analyzedAt != nil {
                        ReasonsSection(photo: photo, burstMembers: burstMembers)
                    }
                    InfoSection(photo: photo)
                }
                .padding(16)
            }
            // A new photo starts at the top, not where the previous one was scrolled.
            .id(photo.id)
        } else {
            ContentUnavailableView {
                Label("Aucune photo sélectionnée", systemImage: "photo")
            } description: {
                Text("Choisissez une photo pour voir pourquoi l'IA l'a classée ainsi.")
            }
        }
    }
}

// MARK: - Header and preview

private struct InspectorHeader: View {
    let photo: Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: photo.fileName)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(verbatim: InspectorInfo.dateLine(date: photo.captureDate, burstNumber: photo.burstNumber))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        // VoiceOver: one heading for the photo, like an `<h1>` at the top of the panel.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The thumbnail, whole, with a dashed box around the subject and « Sujet détecté ».
private struct InspectorPreview: View {
    let photo: Photo
    let loader: ThumbnailLoader
    let canUseOriginals: Bool
    @State private var loadedImage: CGImage?

    static let height: CGFloat = 252

    var body: some View {
        let image = loadedImage ?? loader.cachedThumbnail(for: photo.id)
        // The box is only drawn over the real photo: on a placeholder it would point at nothing.
        let subject = image == nil ? nil : photo.subjectBox
        ZStack(alignment: .bottomLeading) {
            Palette.photoBackground.color
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // The overlay has the size of the drawn photo: the box is placed in its coordinates.
                    .overlay {
                        if let subject {
                            GeometryReader { geometry in
                                SubjectFrame()
                                    .frame(width: subject.width * geometry.size.width, height: subject.height * geometry.size.height)
                                    .offset(x: subject.minX * geometry.size.width, y: subject.minY * geometry.size.height)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: photo.mediaKind == .video ? "video" : "photo")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if subject != nil {
                Text("Sujet détecté")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.badge.color, in: Capsule())
                    .padding(10)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aperçu de la photo"))
        .accessibilityValue(Text(verbatim: subject.map { InspectorSubject.accessibilityDescription(of: $0) } ?? ""))
        .accessibilityAddTraits(.isImage)
        // Like a grid cell: the cached thumbnail, generated if needed; again when the disk comes back.
        .task(id: PreviewTaskKey(photoId: photo.id, canUseOriginals: canUseOriginals)) {
            loadedImage = nil
            if let cached = loader.cachedThumbnail(for: photo.id) {
                loadedImage = cached
            } else {
                loadedImage = await loader.thumbnail(for: photo.thumbnailRequest)
            }
        }
    }
}

private struct PreviewTaskKey: Hashable {
    var photoId: UUID
    var canUseOriginals: Bool
}

/// The dashed box of the subject: white, with a thin dark edge so it shows on a white car as well.
private struct SubjectFrame: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        shape
            .stroke(Color.black.opacity(0.35), lineWidth: 2.5)
            .overlay {
                shape.stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
    }
}

// MARK: - Garder / À revoir / Rejeter

private struct VerdictPicker: View {
    let photo: Photo
    let onSort: (SortingCommand) -> Void

    private static let verdicts: [CullingVerdict] = [.keep, .review, .reject]

    var body: some View {
        let caption = VerdictCaption(photo: photo)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Self.verdicts, id: \.self) { verdict in
                    verdictButton(verdict)
                }
            }
            .padding(3)
            .background(Palette.track.color, in: RoundedRectangle(cornerRadius: Radius.card))
            // Like a `role="group"` with an `aria-label`: VoiceOver says what the three buttons are for.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Tri de cette photo"))

            HStack(spacing: 4) {
                Text(verbatim: caption.text)
                if caption.showsKeys {
                    KeyCap("P"); KeyCap("U"); KeyCap("X")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)

            if caption.canFollowAI {
                Button {
                    onSort(.followAI)
                } label: {
                    HStack(spacing: 4) {
                        Text("Revenir à la proposition de l'IA")
                        KeyCap("A")
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                .padding(.horizontal, 2)
                .help("Oublier votre choix : la proposition de l'IA s'applique de nouveau (A)")
                .accessibilityLabel(Text("Revenir à la proposition de l'IA"))
            }
        }
    }

    private func verdictButton(_ verdict: CullingVerdict) -> some View {
        let isSelected = photo.verdict == verdict
        return Button {
            onSort(.choose(verdict))
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: verdict.symbolName)
                        .font(.system(size: 11, weight: .heavy))
                }
                Text(verbatim: verdict.label)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? verdict.tint : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Palette.chip.color)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                }
            }
            // The whole segment reacts to a click, not only its text.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(verdict.label) (\(SortingCommand.choose(verdict).key))")
        // VoiceOver: « Garder, sélectionné, proposé par l'IA, bouton ».
        .accessibilityLabel(Text(verbatim: verdict.label))
        .accessibilityValue(Text(verbatim: isSelected ? selectedValue : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedValue: String {
        photo.isVerdictChosenByUser ? String(localized: "votre choix") : String(localized: "proposé par l'IA")
    }
}

/// A keyboard key in a sentence, like the mockup's `<kbd>`.
private struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.keyCap.color, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line.color, lineWidth: 0.5))
            .accessibilityLabel(Text(verbatim: key))
    }
}

// MARK: - « Pourquoi ce choix »

private struct ReasonsSection: View {
    let photo: Photo
    let burstMembers: [Photo]

    var body: some View {
        let burst = burstMembers.count > 1 ? BurstContext(photo: photo, members: burstMembers) : nil
        let lines = ReasonExplanations.explanations(
            for: photo.cullingReasons, burst: burst, hasSubject: photo.subjectBox != nil
        )
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(VerdictCaption(photo: photo).reasonsTitle)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                ReasonRow(line: line)
            }
            gauges
                .padding(.top, 2)
        }
    }

    @ViewBuilder private var gauges: some View {
        // Before the details are read, where the sharpness was measured is unknown; the analysis
        // measures it on the subject whenever it finds one, which is the usual case.
        let onSubject = photo.detailsReadAt == nil || photo.subjectBox != nil
        let sharpness = photo.sharpness.map { InspectorGauges.sharpness($0, onSubject: onSubject) }
        let exposure: GaugeReading? = if let highlights = photo.highlightClipping, let shadows = photo.shadowClipping {
            InspectorGauges.exposure(highlights: highlights, shadows: shadows)
        } else {
            nil
        }
        if sharpness != nil || exposure != nil {
            // `Grid` lines up its rows in columns, like a CSS grid with `grid-template-columns`.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                if let sharpness { GaugeRow(title: String(localized: "Netteté"), reading: sharpness) }
                if let exposure { GaugeRow(title: String(localized: "Exposition"), reading: exposure) }
            }
            .font(.system(size: 12))
        }
    }
}

private struct ReasonRow: View {
    let line: ReasonExplanation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: line.symbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: line.title)
                    .fontWeight(.semibold)
                Text(verbatim: line.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    // Wraps over several lines: the inspector has a fixed width, so this is safe here.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch line.tone {
        case .gold: Palette.gold.color
        case .verdict(let verdict): verdict.tint
        }
    }
}

private struct GaugeRow: View {
    let title: String
    let reading: GaugeReading

    var body: some View {
        GridRow {
            Text(verbatim: title)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Capsule()
                .fill(Palette.line.color)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(reading.tone.tint)
                            .frame(width: geometry.size.width * reading.fraction)
                    }
                }
            Text(verbatim: reading.label)
                .foregroundStyle(reading.tone.tint)
                .fontWeight(.medium)
                .lineLimit(1)
                .gridColumnAlignment(.trailing)
        }
        // The numbers stay in the tooltip: « Netteté mesurée sur le sujet : 158 (floue sous 45…) ».
        .help(reading.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: reading.label))
    }
}

// MARK: - « Infos »

private struct InfoSection: View {
    let photo: Photo

    var body: some View {
        let rows = infoRows
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(String(localized: "Infos"))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(rows, id: \.title) { row in
                    GridRow {
                        Text(verbatim: row.title)
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        Text(verbatim: row.value)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: 12))
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line.color).frame(height: 0.5)
        }
    }

    private var infoRows: [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = []
        let capture = photo.capture
        if let camera = InspectorInfo.camera(make: capture.cameraMake, model: capture.cameraModel) {
            rows.append((String(localized: "Appareil"), camera))
        }
        if let lens = capture.lensModel {
            rows.append((String(localized: "Objectif"), lens))
        }
        if let settings = InspectorInfo.settings(capture) {
            rows.append((String(localized: "Réglages"), settings))
        }
        if let duration = photo.videoDuration {
            rows.append((String(localized: "Durée"), InspectorInfo.duration(duration)))
        }
        if photo.mediaKind == .video, photo.pixelWidth > 0 {
            rows.append((String(localized: "Dimensions"), "\(photo.pixelWidth) × \(photo.pixelHeight)"))
        }
        rows.append((String(localized: "Fichier"), InspectorInfo.file(relativePath: photo.relativePath, size: photo.fileSize)))
        return rows
    }
}

/// « Pourquoi ce choix », « Infos »: small grey titles, read as headings by VoiceOver.
private struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
