import AppKit
import UniformTypeIdentifiers

/// Dropping something on the window: a folder becomes a gallery indexed in place (F2), the card of a
/// camera opens the card import (F1), anything else is explained instead.
///
/// The sandbox lets the app read what the user drags onto it, as with the folder picker: the dropped
/// URL can be bookmarked like the one of `NSOpenPanel` (done by `FolderIndexer`). Nothing dropped is
/// ever copied, moved or modified.
enum FolderDrop {
    /// What the app knows about one dropped item, read from the disk by `item(at:)`.
    struct Item: Equatable {
        var name: String
        var isDirectory: Bool
        /// A bundle the Finder shows as a file (a Photos library, an app…).
        var isPackage: Bool = false
        /// The root of a disk (a card, an external drive).
        var isVolumeRoot: Bool = false
        /// The root holds a DCIM folder: the card of a camera.
        var hasCameraFolder: Bool = false
        /// A folder inside the DCIM folder of a removable disk: part of a card.
        var isInsideCameraCard: Bool = false
    }

    enum Decision: Equatable {
        /// F2: a gallery that points at this folder; the files stay where they are.
        case indexFolder(URL)
        /// F1: the card itself was dropped: copy then check, as « Importer une carte SD… ».
        case importCard(URL)
        case rejected(Rejection)
    }

    /// Why a drop is refused, with what to do instead.
    enum Rejection: Equatable {
        case notAFolder(name: String)
        /// Something that is not a file of the Mac (a picture from a web page, some text…).
        case notFromFinder
        case severalItems
        case insideCameraCard(name: String)

        var title: String {
            switch self {
            case .notAFolder, .notFromFinder: String(localized: "Déposez un dossier")
            case .severalItems: String(localized: "Un dossier à la fois")
            case .insideCameraCard: String(localized: "Dossier d'une carte SD")
            }
        }

        var message: String {
            switch self {
            case .notAFolder(let name):
                String(localized: "« \(name) » n'est pas un dossier. LinkLens ajoute des dossiers entiers : glissez le dossier qui contient vos photos, ou choisissez « Ajouter un dossier… » (⌘O).")
            case .notFromFinder:
                String(localized: "LinkLens ajoute des dossiers de photos : glissez un dossier depuis le Finder, ou choisissez « Ajouter un dossier… » (⌘O).")
            case .severalItems:
                String(localized: "Glissez un seul dossier de photos à la fois : chaque dossier devient une galerie.")
            case .insideCameraCard(let name):
                String(localized: "« \(name) » est sur une carte d'appareil photo. Pour garder vos photos après avoir formaté la carte, importez-la : glissez la carte elle-même, ou choisissez « Importer une carte SD… » (⇧⌘I).")
            }
        }
    }

    /// The rule, kept pure so it can be tested without a disk.
    static func decide(_ items: [(url: URL, item: Item)]) -> Decision {
        guard let (url, item) = items.first else {
            return .rejected(.notFromFinder)
        }
        guard items.count == 1 else {
            return .rejected(.severalItems)
        }
        guard item.isDirectory, !item.isPackage else {
            return .rejected(.notAFolder(name: item.name))
        }
        if item.isVolumeRoot && item.hasCameraFolder {
            return .importCard(url)
        }
        if item.isInsideCameraCard {
            return .rejected(.insideCameraCard(name: item.name))
        }
        return .indexFolder(url)
    }

    /// Reads what `decide` needs. Only file attributes and one `fileExists`: nothing is opened.
    static func item(at url: URL) -> Item {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isVolumeKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let values = try? url.resourceValues(forKeys: keys)
        let isVolumeRoot = values?.isVolume ?? false
        let isRemovable = (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false)
        let components = url.standardizedFileURL.pathComponents
        return Item(
            name: url.lastPathComponent,
            isDirectory: values?.isDirectory ?? false,
            isPackage: values?.isPackage ?? false,
            isVolumeRoot: isVolumeRoot,
            hasCameraFolder: isVolumeRoot && CardScanner.hasCameraFolder(url),
            isInsideCameraCard: isRemovable && components.contains(CardScanner.cameraFolder)
        )
    }

    /// The file URLs of a drop, in order. `loadObject` answers on a background thread; `await` waits
    /// for each answer (like awaiting a Promise wrapped around a callback API).
    @MainActor
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            // `withCheckedContinuation` turns a callback into an `await`, like `new Promise(resolve => …)`.
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        return urls
    }
}
