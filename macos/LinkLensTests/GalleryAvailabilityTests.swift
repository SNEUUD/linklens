import Foundation
import SwiftData
import Testing
@testable import LinkLens

/// F9: the decision alone, from plain facts (no disk needed).
struct GalleryAvailabilityTests {
    private let photos2TB = VolumeIdentity(name: "Photos 2TB", uuid: "11111111-2222-3333-4444-555555555555")
    private let system = MountedVolume(path: "/", uuid: "AAAAAAAA-0000-0000-0000-000000000000")

    @Test func aReachableFolderIsAvailable() {
        let availability = GalleryAvailability.evaluate(
            folderPath: "/Volumes/Photos 2TB/Mariage", folderReachable: true,
            remembered: photos2TB, mountedVolumes: [system]
        )
        #expect(availability == .available)
        #expect(availability.canUseOriginals)
        #expect(availability.message == nil)
        #expect(availability.help(for: .export) == nil)
    }

    @Test func anUnpluggedDiskIsNamedAsRemembered() {
        let availability = GalleryAvailability.evaluate(
            folderPath: "/Volumes/Photos 2TB/2026/Mariage", folderReachable: false,
            remembered: photos2TB, mountedVolumes: [system]
        )
        #expect(availability == .diskDisconnected(volumeName: "Photos 2TB"))
        #expect(!availability.canUseOriginals)
        #expect(availability.message == "Disque « Photos 2TB » non connecté")
        #expect(availability.help(for: .export)?.hasPrefix("Disque « Photos 2TB » non connecté.") == true)
    }

    @Test func withoutARememberedNameTheMountPointNamesTheDisk() {
        // A gallery indexed before F9, whose disk was never seen since.
        let availability = GalleryAvailability.evaluate(
            folderPath: "/Volumes/SSD Voyage/Japon", folderReachable: false,
            remembered: nil, mountedVolumes: [system]
        )
        #expect(availability == .diskDisconnected(volumeName: "SSD Voyage"))
    }

    @Test func theDiskBackAtAnotherPathMeansTheFolderIsMissing() {
        // Same disk (same id), mounted as "Photos 2TB 1" because the name was taken: the bookmark
        // would have found the folder, so the folder itself is gone.
        let availability = GalleryAvailability.evaluate(
            folderPath: "/Volumes/Photos 2TB/Mariage", folderReachable: false,
            remembered: photos2TB, mountedVolumes: [system, MountedVolume(path: "/Volumes/Photos 2TB 1", uuid: photos2TB.uuid)]
        )
        #expect(availability == .folderMissing)
    }

    @Test func anotherDiskWithTheSameNameIsNotTheGallerysDisk() {
        let availability = GalleryAvailability.evaluate(
            folderPath: "/Volumes/Photos 2TB/Mariage", folderReachable: false,
            remembered: photos2TB, mountedVolumes: [system, MountedVolume(path: "/Volumes/Photos 2TB", uuid: "OTHER")]
        )
        #expect(availability == .diskDisconnected(volumeName: "Photos 2TB"))
    }

    @Test func withoutAVolumeIdTheMountPointDecides() {
        let fat = VolumeIdentity(name: "CARTE", uuid: nil)
        let mounted = GalleryAvailability.evaluate(
            folderPath: "/Volumes/CARTE/Photos", folderReachable: false,
            remembered: fat, mountedVolumes: [system, MountedVolume(path: "/Volumes/CARTE", uuid: nil)]
        )
        let unplugged = GalleryAvailability.evaluate(
            folderPath: "/Volumes/CARTE/Photos", folderReachable: false,
            remembered: fat, mountedVolumes: [system]
        )
        #expect(mounted == .folderMissing)
        #expect(unplugged == .diskDisconnected(volumeName: "CARTE"))
    }

    @Test func aFolderOnTheMacsOwnDiskIsMissingNotUnplugged() {
        let availability = GalleryAvailability.evaluate(
            folderPath: "/Users/chris/Pictures/Mariage", folderReachable: false,
            remembered: VolumeIdentity(name: "Macintosh HD", uuid: "X"), mountedVolumes: []
        )
        #expect(availability == .folderMissing)
        #expect(availability.message == "Dossier introuvable")
    }

    @Test func mountPointOfAPath() {
        #expect(GalleryAvailability.externalMountPath(of: "/Volumes/Photos 2TB/2026/Mariage") == "/Volumes/Photos 2TB")
        #expect(GalleryAvailability.externalMountPath(of: "/Volumes/Photos 2TB") == "/Volumes/Photos 2TB")
        #expect(GalleryAvailability.externalMountPath(of: "/Volumes") == nil)
        #expect(GalleryAvailability.externalMountPath(of: "/Users/chris/Volumes/x") == nil)
    }
}

/// F9: the checks against real folders (temporary ones, on the Mac's disk).
struct GalleryAvailabilityCheckerTests {
    @Test func aReachableFolderIsAvailableAndItsDiskRemembered() throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        let gallery = try location(of: folder.url)

        let check = GalleryAvailabilityChecker.check(gallery, mountedVolumes: MountedVolume.current())

        #expect(check.availability == .available)
        #expect(check.volume?.name.isEmpty == false)
        #expect(check.refreshedBookmark == nil, "nothing moved: the bookmark is kept")
    }

    @Test func aDeletedFolderIsMissing() throws {
        let folder = try TestFolder()
        let gallery = try location(of: folder.url)
        folder.remove()

        let check = GalleryAvailabilityChecker.check(gallery, mountedVolumes: MountedVolume.current())

        #expect(check.availability == .folderMissing)
    }

    @Test func aRenamedFolderIsFollowedAndItsBookmarkRefreshed() throws {
        let folder = try TestFolder()
        let renamed = folder.url.deletingLastPathComponent().appending(path: "\(folder.url.lastPathComponent)-renamed")
        defer { folder.remove(); try? FileManager.default.removeItem(at: renamed) }
        let gallery = try location(of: folder.url)
        try FileManager.default.moveItem(at: folder.url, to: renamed)

        let check = GalleryAvailabilityChecker.check(gallery, mountedVolumes: MountedVolume.current())

        #expect(check.availability == .available)
        #expect(check.refreshedFolderPath == FolderBookmark.canonicalPath(of: renamed))
        let bookmark = try #require(check.refreshedBookmark)
        #expect(FolderBookmark.canonicalPath(of: try FolderBookmark.resolve(bookmark)) == FolderBookmark.canonicalPath(of: renamed))
    }

    @Test func aFolderInTheTrashIsMissing() throws {
        let (folder, parent) = try (TestFolder(), TestFolder())
        defer { folder.remove(); parent.remove() }
        let gallery = try location(of: folder.url)
        let trash = parent.url.appending(path: ".Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder.url, to: trash.appending(path: folder.url.lastPathComponent))

        let check = GalleryAvailabilityChecker.check(gallery, mountedVolumes: MountedVolume.current())

        #expect(check.availability == .folderMissing)
    }

    @Test func aDiskThatIsNotMountedIsReportedByName() {
        let gallery = GalleryLocation(
            id: UUID(), name: "Mariage", folderPath: "/Volumes/LinkLensTests-\(UUID().uuidString)/Mariage",
            createdAt: Date(), folderBookmark: Data("pas un bookmark".utf8), writeBookmark: nil,
            volumeName: "Photos 2TB", volumeUUID: UUID().uuidString
        )

        let check = GalleryAvailabilityChecker.check(gallery, mountedVolumes: MountedVolume.current())

        #expect(check.availability == .diskDisconnected(volumeName: "Photos 2TB"))
        #expect(check.volume == nil && check.refreshedBookmark == nil, "nothing is saved for an unreachable folder")
    }

    private func location(of url: URL) throws -> GalleryLocation {
        GalleryLocation(
            id: UUID(), name: url.lastPathComponent, folderPath: FolderBookmark.canonicalPath(of: url),
            createdAt: Date(), folderBookmark: try FolderBookmark.create(for: url), writeBookmark: nil
        )
    }
}

/// F9: the monitor, with a real catalogue (in memory) and folders that go away and come back.
@MainActor
struct GalleryAvailabilityMonitorTests {
    @Test func followsAFolderThatGoesAwayAndComesBack() async throws {
        let (folder, parent) = try (TestFolder(), TestFolder())
        defer { folder.remove(); parent.remove() }
        try folder.writeJPEG("a.jpg")
        let container = try makeInMemoryContainer()
        let store = LibraryStore(modelContainer: container)
        let galleryId = try await indexTestGallery(folder, store: store)
        // The indexing already remembers the disk.
        #expect(try await store.galleryLocations().first?.volumeName?.isEmpty == false)

        let monitor = GalleryAvailabilityMonitor(store: store)
        var backOnline: [[UUID]] = []
        monitor.onGalleriesBecameAvailable = { backOnline.append($0) }
        monitor.refresh()
        await monitor.waitUntilIdle()
        #expect(monitor.availability(of: galleryId) == .available)

        // Out of reach (a bookmark follows its folder, so it is moved into a trash folder).
        let trash = parent.url.appending(path: ".Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let away = trash.appending(path: folder.url.lastPathComponent)
        try FileManager.default.moveItem(at: folder.url, to: away)
        monitor.refresh()
        await monitor.waitUntilIdle()
        #expect(monitor.availability(of: galleryId) == .folderMissing)
        #expect(backOnline.isEmpty)

        // Back: available again, the app is told, the saved path did not move.
        try FileManager.default.moveItem(at: away, to: folder.url)
        monitor.refresh()
        await monitor.waitUntilIdle()
        #expect(monitor.availability(of: galleryId) == .available)
        #expect(backOnline == [[galleryId]])
        #expect(try await store.galleryLocations().first?.folderPath == FolderBookmark.canonicalPath(of: folder.url))
    }

    @Test func savesTheNewPlaceOfARenamedFolder() async throws {
        let folder = try TestFolder()
        let renamed = folder.url.deletingLastPathComponent().appending(path: "\(folder.url.lastPathComponent)-renamed")
        defer { folder.remove(); try? FileManager.default.removeItem(at: renamed) }
        try folder.writeJPEG("a.jpg")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        let galleryId = try await indexTestGallery(folder, store: store)
        try FileManager.default.moveItem(at: folder.url, to: renamed)

        let monitor = GalleryAvailabilityMonitor(store: store)
        monitor.refresh()
        await monitor.waitUntilIdle()

        #expect(monitor.availability(of: galleryId) == .available)
        let saved = try #require(try await store.galleryLocations().first)
        #expect(saved.folderPath == FolderBookmark.canonicalPath(of: renamed))
        #expect(FolderBookmark.canonicalPath(of: try FolderBookmark.resolve(saved.folderBookmark)) == saved.folderPath)
    }

    @Test func manyRefreshesInARowEndWithOneConsistentState() async throws {
        let folder = try TestFolder()
        defer { folder.remove() }
        try folder.writeJPEG("a.jpg")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        let galleryId = try await indexTestGallery(folder, store: store)
        let monitor = GalleryAvailabilityMonitor(store: store)

        for _ in 0..<20 { monitor.refresh() }
        await monitor.waitUntilIdle()

        #expect(monitor.states == [galleryId: .available])
    }
}

/// F9: the thumbnails of a gallery whose disk goes away while it is shown.
@MainActor
struct ThumbnailLoaderUnpluggedTests {
    @Test func aFolderGoingAwayMarksNoPhotoAsUnreadable() async throws {
        let (photos, cacheFolder, parent) = try (TestFolder(), TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove(); parent.remove() }
        try photos.writeJPEG("a.jpg")
        try photos.writeJPEG("b.jpg")
        let first = ThumbnailRequest(photoId: UUID(), relativePath: "a.jpg")
        let second = ThumbnailRequest(photoId: UUID(), relativePath: "b.jpg")
        let cache = ThumbnailCache(directory: cacheFolder.url)
        let bookmark = try FolderBookmark.create(for: photos.url)
        let loader = ThumbnailLoader(cache: cache)
        loader.open(folderBookmark: bookmark)
        defer { loader.stop() }
        #expect(await loader.thumbnail(for: first) != nil)

        // The disk is pulled out: the folder is gone from its path.
        let away = parent.url.appending(path: "away", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: photos.url, to: away)

        #expect(await loader.thumbnail(for: second) == nil)
        #expect(loader.folder == nil, "the loader let the folder go instead of retrying every photo")
        #expect(await loader.thumbnail(for: first) != nil, "the cached thumbnail is still shown")

        // Plugged back in: the same photo is generated, it was not marked as unreadable.
        try FileManager.default.moveItem(at: away, to: photos.url)
        loader.open(folderBookmark: bookmark)
        #expect(await loader.thumbnail(for: second) != nil)
        #expect(cache.contains(second.photoId))
    }

    @Test func closingTheFolderKeepsServingTheCache() async throws {
        let (photos, cacheFolder) = try (TestFolder(), TestFolder())
        defer { photos.remove(); cacheFolder.remove() }
        try photos.writeJPEG("a.jpg")
        let request = ThumbnailRequest(photoId: UUID(), relativePath: "a.jpg")
        let bookmark = try FolderBookmark.create(for: photos.url)
        let loader = ThumbnailLoader(cache: ThumbnailCache(directory: cacheFolder.url))
        loader.open(folderBookmark: bookmark)
        defer { loader.stop() }
        #expect(await loader.thumbnail(for: request) != nil)

        loader.closeFolder()

        #expect(loader.folder == nil)
        #expect(await loader.thumbnail(for: request) != nil)
        #expect(await loader.preview(for: ThumbnailRequest(photoId: UUID(), relativePath: "a.jpg")) == nil)
        loader.open(folderBookmark: bookmark)
        #expect(loader.folder != nil)
    }
}

/// F9: duplicates on an unplugged disk are left where they are.
@MainActor
struct DuplicatesUnpluggedTests {
    @Test func copiesOnAnUnpluggedDiskAreNeverSelected() async throws {
        let name = "DSC-\(UUID().uuidString.prefix(8)).ARW"
        let (first, second) = try (TestFolder(), TestFolder())
        defer { first.remove(); second.remove() }
        try first.writeFile(name, contents: "same picture")
        try second.writeFile(name, contents: "same picture")
        let store = LibraryStore(modelContainer: try makeInMemoryContainer())
        let firstId = try await indexTestGallery(first, store: store)
        let secondId = try await indexTestGallery(second, store: store)
        var asked = 0
        let controller = DuplicatesController(store: store) { _ in
            asked += 1
            return nil
        }
        let unplugged = TestValue<Set<UUID>>([secondId])
        controller.galleryAvailability = { unplugged.value.contains($0) ? .diskDisconnected(volumeName: "Photos 2TB") : .available }
        controller.scan()
        await controller.waitUntilIdle()
        let group = try #require(controller.report?.groups.first)
        let secondCopy = try #require(group.copies.first { $0.galleryId == secondId })

        // The proposal keeps the older gallery's copy; the other one is on the unplugged disk.
        #expect(controller.keptPhotoId(in: group) == group.copies.first { $0.galleryId == firstId }?.photoId)
        #expect(controller.selectedCopyCount == 0)
        #expect(controller.availability(of: secondCopy) == .diskDisconnected(volumeName: "Photos 2TB"))
        // Keeping the unplugged copy: it cannot be read again, so nothing moves.
        controller.keep(secondCopy.photoId, in: group)
        #expect(controller.selectedCopyCount == 0)
        controller.moveSelectionToTrash()
        await controller.waitUntilIdle()
        #expect(asked == 0)
        #expect(FileManager.default.fileExists(atPath: first.url.appending(path: name).path))

        // The disk is back.
        unplugged.value = []
        #expect(controller.selectedCopyCount == 1)
    }
}

/// Indexes a test folder as a gallery (F2) and returns its id.
private func indexTestGallery(_ folder: TestFolder, store: LibraryStore) async throws -> UUID {
    switch try await FolderIndexer(store: store).indexFolder(at: folder.url) {
    case .indexed(let galleryId, _), .alreadyIndexed(let galleryId):
        return galleryId
    }
}
