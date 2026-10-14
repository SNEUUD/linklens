import AppKit
import Observation

/// What the app may know about a mounted volume without the user's consent.
struct VolumeInfo: Sendable, Equatable {
    var url: URL
    var name: String
    var isRemovable: Bool
    var isEjectable: Bool
    var isLocal: Bool
    var isRootFileSystem: Bool
    /// File system ("msdos" for FAT32, "exfat"…). Camera cards are always FAT32 or exFAT.
    var fileSystem: String?
    /// True / false when the volume can be listed; nil when the sandbox does not allow it yet.
    var hasCameraFolder: Bool?

    /// A volume worth offering « Importer la carte » for: a removable FAT or exFAT disk with a DCIM
    /// folder. The sandbox usually hides the contents until the user picks the card, so the
    /// file system stands in for the DCIM check; the folder picker checks DCIM afterwards.
    var looksLikeCameraCard: Bool {
        guard isLocal, !isRootFileSystem, isRemovable || isEjectable else { return false }
        if let hasCameraFolder { return hasCameraFolder }
        return ["msdos", "exfat"].contains(fileSystem?.lowercased() ?? "")
    }

    static func read(_ url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeTypeNameKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        // Listing fails when the sandbox has not been granted the volume: that is "unknown", not "no".
        let hasCameraFolder = (try? FileManager.default.contentsOfDirectory(atPath: url.path))
            .map { names in names.contains { $0.caseInsensitiveCompare(CardScanner.cameraFolder) == .orderedSame } }
        return VolumeInfo(
            url: url,
            name: values.volumeLocalizedName ?? url.lastPathComponent,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isLocal: values.volumeIsLocal ?? false,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            fileSystem: values.volumeTypeName,
            hasCameraFolder: hasCameraFolder
        )
    }
}

/// A card shown in the « Carte détectée » banner.
struct DetectedCard: Sendable, Identifiable, Equatable {
    var url: URL
    var name: String
    var id: URL { url }
}

/// Watches cards being inserted and removed.
///
/// macOS posts a notification on `NSWorkspace.shared.notificationCenter` when a volume is mounted or
/// unmounted (like `window.addEventListener`); the app only listens, it needs no entitlement for that.
@MainActor
@Observable
final class CardMonitor {
    /// Cards waiting for an import, in insertion order.
    private(set) var cards: [DetectedCard] = []
    /// Cards the user closed the banner of; they come back when inserted again.
    @ObservationIgnored private var dismissed: Set<URL> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Starts listening, and offers the cards already inserted when the app opens.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { notification in
            // The URL is read here: a `Notification` cannot cross to another actor, a `URL` can.
            let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            // `queue: .main` delivers on the main thread; `assumeIsolated` tells the compiler so.
            MainActor.assumeIsolated {
                if let url { self.volumeMounted(url) }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { notification in
            let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                if let url { self.volumeUnmounted(url) }
            }
        })
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for url in mounted {
            volumeMounted(url)
        }
    }

    /// Hides the banner of this card until it is inserted again.
    func dismiss(_ card: DetectedCard) {
        dismissed.insert(card.url.standardizedFileURL)
        cards.removeAll { $0.id == card.id }
    }

    func volumeMounted(_ url: URL) {
        let key = url.standardizedFileURL
        guard !dismissed.contains(key), !cards.contains(where: { $0.url.standardizedFileURL == key }),
              let info = VolumeInfo.read(url), info.looksLikeCameraCard
        else { return }
        cards.append(DetectedCard(url: url, name: info.name))
    }

    func volumeUnmounted(_ url: URL) {
        let key = url.standardizedFileURL
        dismissed.remove(key)
        cards.removeAll { $0.url.standardizedFileURL == key }
    }
}
