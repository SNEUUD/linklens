import SwiftUI

/// First launch, no gallery yet: what LinkLens does, in three steps, and the two ways to start.
/// Shown in place of the gallery until the first one is added.
struct WelcomeView: View {
    /// A folder is being dragged over the window: the drop zone lights up.
    var isDropTargeted = false
    @Environment(ImportController.self) private var importController
    @Environment(CardImportController.self) private var cardImportController

    var body: some View {
        // In a small window the screen scrolls instead of forcing the window to grow.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 36) {
                    header
                    steps
                    actions
                    dropZone
                }
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            LensMark(size: 76)
                .accessibilityHidden(true)
            Text("Bienvenue dans LinkLens")
                .font(.system(size: 34, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text("Triez une séance en quelques minutes. L'IA propose Garder, À revoir ou Rejeter, et vous dit pourquoi. C'est toujours vous qui décidez.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 520)
        }
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: 16) {
            WelcomeStep(
                number: 1,
                title: "Importer",
                text: "Une carte SD ou un dossier déjà rangé. Chaque fichier copié est vérifié avant de vous proposer de formater la carte."
            )
            WelcomeStep(
                number: 2,
                title: "Trier",
                text: "Les rafales sont regroupées et la meilleure photo mise en avant. Changez d'avis avec P, U ou X."
            )
            WelcomeStep(
                number: 3,
                title: "Exporter",
                text: "En JPEG pour le web ou l'impression, en HEIC ou en TIFF. Les originaux ne sont jamais modifiés."
            )
        }
        // Same height for the three cards: each one stretches to the tallest.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 900)
        // VoiceOver: « Étapes, liste de 3 éléments ».
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Étapes")
    }

    private var actions: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button(action: cardImportController.chooseCard) {
                    Label("Importer une carte SD…", systemImage: "sdcard")
                }
                .buttonStyle(.capsule(.prominent, size: .large))
                .disabled(cardImportController.isSheetPresented)
                .help("Copier les photos et vidéos d'une carte SD dans une nouvelle galerie")
                .accessibilityHint("Raccourci : Majuscule Commande I")

                Button(action: importController.chooseFolder) {
                    Label("Ajouter un dossier…", systemImage: "folder")
                }
                .buttonStyle(.capsule(.secondary, size: .large))
                .disabled(importController.isIndexing)
                .help("Indexer un dossier de photos sans le copier")
                .accessibilityHint("Raccourci : Commande O")
            }
            // The shortcuts themselves belong to the File menu (one owner): they are only shown here.
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    KeyCap("⇧⌘I")
                    Text("carte")
                }
                HStack(spacing: 5) {
                    KeyCap("⌘O")
                    Text("dossier")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            // Already in the hints of the two buttons.
            .accessibilityHidden(true)
        }
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "folder.badge.plus" : "square.and.arrow.down")
                .font(.system(size: 17))
                .accessibilityHidden(true)
            Text(isDropTargeted ? "Déposez le dossier pour l'ajouter" : "Ou glissez un dossier de photos dans cette fenêtre")
                .fontWeight(isDropTargeted ? .semibold : .regular)
        }
        .foregroundStyle(isDropTargeted ? AnyShapeStyle(Palette.accent.color) : AnyShapeStyle(.secondary))
        .frame(maxWidth: 900)
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(isDropTargeted ? Palette.accentSoft.color : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDropTargeted ? Palette.accent.color : Color.primary.opacity(0.18),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: [6, 4])
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zone de dépôt")
        .accessibilityValue(isDropTargeted
            ? Text("Déposez le dossier pour l'ajouter")
            : Text("Glissez un dossier de photos dans cette fenêtre pour en faire une galerie. Les fichiers restent à leur place."))
    }
}

/// One numbered card: « 1 Importer » and what happens at that step.
private struct WelcomeStep: View {
    let number: Int
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(verbatim: "\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.accent.color)
                    .frame(width: 28, height: 28)
                    .background(Palette.accentSoft.color, in: Circle())
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            Text(text)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.color, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        // VoiceOver reads one card at a time: « Étape 1, Importer. Une carte SD… ».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Étape \(number) : ") + Text(title))
        .accessibilityValue(Text(text))
        .accessibilityAddTraits(.isHeader)
    }
}

/// The LinkLens lens in a rounded square, as in the mockup and the app icon.
struct LensMark: View {
    var size: CGFloat = 76

    var body: some View {
        // The mockup draws it in a 76 × 76 box; everything scales from there.
        let scale = size / 76
        ZStack {
            RoundedRectangle(cornerRadius: 18 * scale)
                .fill(Palette.card.color)
                .overlay(RoundedRectangle(cornerRadius: 18 * scale).strokeBorder(Palette.line.color, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 4 * scale, y: 2 * scale)
                .padding(2 * scale)
            Circle()
                .stroke(Palette.accent.color, lineWidth: 3 * scale)
                .frame(width: 42 * scale, height: 42 * scale)
            Circle()
                .fill(Palette.accent.color)
                .frame(width: 18 * scale, height: 18 * scale)
            Path { path in
                // The four marks of the viewfinder, between the ring and the edge.
                for (from, to) in [((38, 17), (38, 23)), ((38, 53), (38, 59)), ((17, 38), (23, 38)), ((53, 38), (59, 38))] {
                    path.move(to: CGPoint(x: Double(from.0) * scale, y: Double(from.1) * scale))
                    path.addLine(to: CGPoint(x: Double(to.0) * scale, y: Double(to.1) * scale))
                }
            }
            .stroke(Palette.accent.color, style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Over the whole window while a folder is dragged over it: a tinted dashed frame and, when a gallery
/// is shown, a message in the middle (the welcome screen has its own drop zone).
struct FolderDropHighlight: View {
    var showsMessage: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.panel)
                .fill(Palette.accentSoft.color.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.panel)
                        .strokeBorder(Palette.accent.color, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                }
                .padding(6)
            if showsMessage {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.accent.color)
                    Text("Déposez le dossier pour l'ajouter")
                        .font(.system(size: 17, weight: .bold))
                    Text("Les photos restent à leur place : rien n'est copié ni déplacé.")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .glassBackground(in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
