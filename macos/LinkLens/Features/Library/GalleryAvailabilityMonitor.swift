import AppKit
import Observation
import os

/// F9: knows, for every gallery, whether its original files can be read right now, and keeps it up
/// to date without restarting the app.
///
/// Checks run at launch, when a disk is mounted or unmounted, when the user comes back to the app
/// (a folder may have been moved in the Finder meanwhile), and when a gallery is added. The views
/// read `availability(of:)`: since the class is `@Observable`, they redraw when it changes, like a
/// React component subscribed to a store.
@MainActor
@Observable
final class GalleryAvailabilityMonitor {
    private(set) var states: [UUID: GalleryAvailability] = [:]
    /// Called after a check during which at least one gallery became available again (its disk was
    /// plugged back in): the app uses it to sort the galleries that could not be sorted meanwhile.
    @ObservationIgnored var onGalleriesBecameAvailable: (@MainActor ([UUID]) -> Void)?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    private nonisolated static let logger = Logger(subsystem: "fr.chriscrepin.linklens", category: "availability")

    init(store: LibraryStore) {
        self.store = store
    }

    /// Available until checked: a gallery just added is reachable, and the first check takes a moment.
    func availability(of galleryId: UUID) -> GalleryAvailability {
        states[galleryId] ?? .available
    }

    /// Starts listening to the disks, and checks every gallery once.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                // `queue: .main` delivers on the main thread; `assumeIsolated` tells the compiler so.
                MainActor.assumeIsolated { self.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.refresh() }
        })
        refresh()
    }

    /// Checks every gallery again. Several calls in a row (a disk with three volumes mounts three
    /// times) are merged: at most one check runs, and one more follows if asked meanwhile.
    func refresh() {
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while needsRefresh {
                needsRefresh = false
                await checkAll()
            }
            refreshTask = nil
        }
    }

    /// Returns once no check is running (used by the tests).
    func waitUntilIdle() async {
        while let task = refreshTask {
            await task.value
        }
    }

    private func checkAll() async {
        guard let galleries = try? await store.galleryLocations() else { return }
        let checks = await GalleryAvailabilityChecker.check(galleries)
        // The disk name is saved while the disk is there, so it can be shown once it is gone.
        do {
            try await store.saveAvailabilityChecks(checks)
        } catch {
            Self.logger.error("Could not save the availability checks: \(error.localizedDescription, privacy: .public)")
        }

        var newStates: [UUID: GalleryAvailability] = [:]
        var backOnline: [UUID] = []
        for check in checks {
            newStates[check.galleryId] = check.availability
            let previous = states[check.galleryId]
            if previous != check.availability {
                Self.logger.notice("Gallery \(check.galleryId, privacy: .public): \(String(describing: check.availability), privacy: .public)")
            }
            if let previous, !previous.canUseOriginals, check.availability.canUseOriginals {
                backOnline.append(check.galleryId)
            }
        }
        // Assigned only when something changed: an unchanged check does not redraw every view.
        if newStates != states {
            states = newStates
        }
        if !backOnline.isEmpty {
            onGalleriesBecameAvailable?(backOnline)
        }
    }
}
