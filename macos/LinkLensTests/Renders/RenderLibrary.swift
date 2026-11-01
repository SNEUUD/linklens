import CoreGraphics
import ImageIO
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import LinkLens

/// A small in-memory catalogue for the interface renders: three galleries with drawn « photos »,
/// verdicts, bursts and cached thumbnails. Nothing touches the real catalogue or thumbnail cache.
@MainActor
final class RenderLibrary {
    let container: ModelContainer
    let store: LibraryStore
    let cache: ThumbnailCache
    /// 52 photos, 12 / 14 / 26 with two choices of the user, 12 bursts, real thumbnails: the session of September 20.
    let session: Gallery
    /// 180 photos on an external disk (unplugged in the sidebar render).
    let wedding: Gallery
    /// 24 photos, never sorted, no thumbnail yet.
    let forest: Gallery
    /// The controllers given to the views, kept here so a render can put them in a given state.
    let exportController = ExportController()
    let availabilityMonitor: GalleryAvailabilityMonitor
    let detailsController: DetailsBackfillController
    /// Its own thumbnail cache and purge file: never the app's.
    let deletionController: GalleryDeletionController
    /// Same: its own cache and purge file, and a trash that is never called by the renders.
    let photoDeletion: PhotoDeletionController
    /// A review can be opened or left half-way before a render.
    let reviewController = ReviewController()

    init() throws {
        container = try ModelContainer(
            for: Gallery.self, Photo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = LibraryStore(modelContainer: container)
        availabilityMonitor = GalleryAvailabilityMonitor(store: store)
        detailsController = DetailsBackfillController(store: store)
        cache = ThumbnailCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "LinkLensRenderThumbnails-\(UUID().uuidString)", directoryHint: .isDirectory))
        deletionController = GalleryDeletionController(
            store: store, cache: cache,
            purgeQueue: ThumbnailPurgeQueue(fileURL: cache.directory.appending(path: "PendingThumbnailRemovals.json"))
        )
        photoDeletion = PhotoDeletionController(
            store: store, cache: cache,
            purgeQueue: ThumbnailPurgeQueue(fileURL: cache.directory.appending(path: "PendingThumbnailRemovals.json"))
        )
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_789_908_057) // 20 Sept. 2026, 14:40:57 in Paris (12:40:57 UTC)

        session = Self.gallery("Séance du 20 sept.", path: realHomeDirectory() + "/Downloads/photos", created: start, in: context)
        wedding = Self.gallery("Mariage Julie & Tom", path: "/Volumes/Photos 2TB/2026/2026-09-12 Mariage", created: start - 86_400 * 8, in: context)
        forest = Self.gallery("Balade en forêt", path: realHomeDirectory() + "/Pictures/Forêt", created: start - 86_400 * 20, in: context)

        // The real session of September 20 (~/Downloads/photos): 52 RAW files, 12 bursts and two single
        // photos, 12 / 14 / 26, the best photo of each burst as in the mockup.
        let sessionPhotos = Self.photos(count: 52, prefix: "DSC0", firstNumber: 4297, start: start, gallery: session, in: context) { _, _ in }
        var burstNumber = 0
        var reviewSlots = Set((0..<14).map { $0 * 38 / 14 }) // 14 « À revoir » spread over the 38 other photos
        var otherIndex = 0
        for burst in Self.realBursts {
            let members = sessionPhotos.filter { burst.numbers.contains(Self.number(of: $0)) }
            if members.count > 1 { burstNumber += 1 }
            for photo in members {
                let isBest = members.count > 1 && Self.number(of: photo) == burst.best
                if members.count > 1 {
                    photo.burstNumber = burstNumber
                    photo.isBestOfBurst = isBest
                }
                if isBest {
                    photo.cullingVerdictRaw = "keep"
                } else if members.count == 1 {
                    photo.cullingVerdictRaw = "reject" // 04317 and 04335, as in the mockup
                } else {
                    photo.cullingVerdictRaw = reviewSlots.remove(otherIndex) != nil ? "review" : "reject"
                    otherIndex += 1
                }
                photo.aestheticsScore = isBest ? 0.8 : 0.3
                Self.applyRealAnalysis(to: photo, start: start, best: "DSC0\(burst.best).ARW", isSingle: members.count == 1)
            }
        }
        // Two choices of the user: 04311 confirmed « Garder », 04312 put back to « À revoir ».
        sessionPhotos[14].userVerdictRaw = "keep"
        sessionPhotos[15].userVerdictRaw = "review"
        session.culledAt = start + 120

        let weddingPhotos = Self.photos(count: 180, prefix: "IMG_", firstNumber: 1001, start: start - 86_400 * 8, gallery: wedding, in: context) { index, photo in
            photo.cullingVerdictRaw = index % 9 < 2 ? "keep" : index % 9 < 5 ? "review" : "reject"
            if index % 10 < 4 { photo.burstNumber = index / 10 + 1 }
            photo.aestheticsScore = Double((index * 53) % 100) / 100
        }
        wedding.culledAt = start
        wedding.volumeName = "Photos 2TB"

        _ = Self.photos(count: 24, prefix: "P10", firstNumber: 100, start: start - 86_400 * 20, gallery: forest, in: context) { _, _ in }

        try context.save()
        // Thumbnails: real ones for the session (each photo of a burst gets its best photo's, the
        // 14 JPEGs of `Fixtures/Thumbnails`), drawn ones for the wedding.
        for photo in sessionPhotos {
            let burst = Self.realBursts.first { $0.numbers.contains(Self.number(of: photo)) }
            try cache.store(try Self.fixtureThumbnail(burst?.best ?? Self.number(of: photo)), for: photo.id)
        }
        for (index, photo) in weddingPhotos.enumerated() where index < 40 {
            try cache.store(Self.drawnPhoto(seed: index + 100), for: photo.id)
        }
        // As in the app: an unplugged disk turns « Supprimer… » into « Mettre en attente de corbeille… ».
        let monitor = availabilityMonitor
        photoDeletion.galleryAvailability = { monitor.availability(of: $0) }
    }

    deinit {
        try? FileManager.default.removeItem(at: cache.directory)
    }

    var galleries: [Gallery] { [session, wedding, forest] }

    /// The same catalogue emptied: the first launch.
    static func empty() throws -> RenderLibrary {
        let library = try RenderLibrary()
        for gallery in library.galleries { library.container.mainContext.delete(gallery) }
        try library.container.mainContext.save()
        return library
    }

    /// The real main window, with the controllers it needs, showing `selectedGallery`.
    /// `isDropTargeted`: as while a folder is dragged over the window. `cardImport`: a controller
    /// prepared by the test (the card import window is shown when it has a card).
    func mainWindow(selecting selectedGallery: Gallery?, isDropTargeted: Bool = false, cardImport: CardImportController? = nil) -> some View {
        let importController = ImportController(store: store)
        importController.selectedGalleryId = selectedGallery?.id
        return withEnvironment(ContentView(isDropTargeted: isDropTargeted), importController: importController, cardImport: cardImport)
            .frame(minWidth: 1080, minHeight: 560)
    }

    /// Gives `view` every object the app provides at its root, with this catalogue and cache.
    func withEnvironment(_ view: some View, importController: ImportController? = nil, cardImport: CardImportController? = nil) -> some View {
        view
            .environment(importController ?? ImportController(store: store))
            .environment(CullingController(store: store))
            .environment(exportController)
            .environment(cardImport ?? makeCardImportController())
            .environment(CardMonitor())
            .environment(DuplicatesController(store: store))
            .environment(availabilityMonitor)
            .environment(detailsController)
            .environment(deletionController)
            .environment(photoDeletion)
            .environment(reviewController)
            .environment(\.thumbnailCache, cache)
            .modelContainer(container)
    }

    /// Never the app's real default location: its own key in the user defaults.
    func makeCardImportController() -> CardImportController {
        CardImportController(
            importer: CardImporter(store: store),
            destinations: ImportDestinationStore(key: "renders.cardImport.defaultDestination")
        )
    }

    // MARK: - Building

    /// The bursts of the real session, in order: their photo numbers and their best photo (itself for a
    /// single photo). Counted from the mockup: 3, 2, 5, 7, 3, 1, 6, 5, 3, 3, 1, 5, 5, 3 = 52 photos.
    private static let realBursts: [(numbers: ClosedRange<Int>, best: Int)] = [
        (4297...4299, 4298), (4300...4301, 4300), (4302...4306, 4304), (4307...4313, 4311),
        (4314...4316, 4315), (4317...4317, 4317), (4318...4323, 4320), (4324...4328, 4327),
        (4329...4331, 4331), (4332...4334, 4332), (4335...4335, 4335), (4336...4340, 4337),
        (4341...4345, 4342), (4346...4348, 4346),
    ]

    /// Measured by the probe on the real files (probe-output/report.json): seconds after the first photo,
    /// sharpness, burnt highlights, blocked shadows and subject box (top-left origin).
    private static let realAnalysis: [Int: (seconds: Double, sharpness: Double, highlights: Double, shadows: Double, subject: CGRect?)] = {
        let rows: [(Int, Double, Double, Double, Double, CGRect?)] = [
        (4297, 0, 48.3, 0.0000, 0.0013, CGRect(x: 0.2084, y: 0.3882, width: 0.5026, height: 0.1665)),
        (4298, 0, 80.8, 0.0000, 0.0014, CGRect(x: 0.2878, y: 0.3628, width: 0.5442, height: 0.1836)),
        (4299, 0, 41.4, 0.0000, 0.0010, CGRect(x: 0.4163, y: 0.3740, width: 0.5510, height: 0.1758)),
        (4300, 3, 122.7, 0.0013, 0.0007, CGRect(x: 0.3069, y: 0.4297, width: 0.4729, height: 0.1724)),
        (4301, 3, 53.2, 0.0082, 0.0003, CGRect(x: 0.2712, y: 0.4246, width: 0.4539, height: 0.1594)),
        (4302, 7, 49.7, 0.0000, 0.0003, CGRect(x: 0.2681, y: 0.4526, width: 0.4346, height: 0.1411)),
        (4303, 7, 45.5, 0.0000, 0.0003, CGRect(x: 0.2776, y: 0.4124, width: 0.4500, height: 0.1609)),
        (4304, 7, 117.6, 0.0000, 0.0005, CGRect(x: 0.3210, y: 0.4434, width: 0.4548, height: 0.1455)),
        (4305, 7, 79.3, 0.0000, 0.0005, CGRect(x: 0.3088, y: 0.4146, width: 0.4729, height: 0.1675)),
        (4306, 7, 100.7, 0.0000, 0.0005, CGRect(x: 0.3074, y: 0.4736, width: 0.5154, height: 0.1548)),
        (4307, 9, 135.3, 0.0000, 0.0001, CGRect(x: 0.3806, y: 0.4614, width: 0.5574, height: 0.1860)),
        (4308, 9, 139.1, 0.0000, 0.0001, CGRect(x: 0.3472, y: 0.4514, width: 0.5864, height: 0.1697)),
        (4309, 9, 78.0, 0.0000, 0.0001, CGRect(x: 0.2603, y: 0.3828, width: 0.5908, height: 0.2114)),
        (4310, 9, 131.9, 0.0000, 0.0002, CGRect(x: 0.1810, y: 0.3435, width: 0.6124, height: 0.2009)),
        (4311, 9, 158.4, 0.0000, 0.0002, CGRect(x: 0.1029, y: 0.3435, width: 0.6593, height: 0.1951)),
        (4312, 9, 146.8, 0.0000, 0.0002, CGRect(x: 0.0786, y: 0.3831, width: 0.6407, height: 0.2302)),
        (4313, 9, 96.9, 0.0000, 0.0000, CGRect(x: 0.1492, y: 0.4336, width: 0.6599, height: 0.2158)),
        (4314, 13, 73.2, 0.0000, 0.0005, CGRect(x: 0.2590, y: 0.4568, width: 0.6174, height: 0.1936)),
        (4315, 13, 95.9, 0.0000, 0.0008, CGRect(x: 0.2301, y: 0.3945, width: 0.6327, height: 0.2227)),
        (4316, 13, 52.8, 0.0000, 0.0004, CGRect(x: 0.2788, y: 0.3750, width: 0.6548, height: 0.2119)),
        (4317, 13, 34.0, 0.0000, 0.0004, CGRect(x: 0.4812, y: 0.3403, width: 0.5042, height: 0.2192)),
        (4318, 15, 132.2, 0.0000, 0.0003, CGRect(x: 0.1049, y: 0.3936, width: 0.5723, height: 0.2119)),
        (4319, 15, 71.3, 0.0000, 0.0002, CGRect(x: 0.1964, y: 0.3953, width: 0.5721, height: 0.1990)),
        (4320, 15, 136.7, 0.0000, 0.0004, CGRect(x: 0.2590, y: 0.3850, width: 0.5994, height: 0.2166)),
        (4321, 16, 70.8, 0.0000, 0.0003, CGRect(x: 0.2416, y: 0.3889, width: 0.5885, height: 0.2122)),
        (4322, 16, 76.8, 0.0000, 0.0002, CGRect(x: 0.0862, y: 0.3862, width: 0.6223, height: 0.2275)),
        (4323, 16, 56.3, 0.0000, 0.0003, CGRect(x: 0.0003, y: 0.3818, width: 0.6252, height: 0.2197)),
        (4324, 25, 62.0, 0.0000, 0.0002, CGRect(x: 0.2095, y: 0.4441, width: 0.4204, height: 0.1887)),
        (4325, 25, 44.4, 0.0000, 0.0003, CGRect(x: 0.1592, y: 0.3936, width: 0.4893, height: 0.1650)),
        (4326, 25, 61.6, 0.0000, 0.0005, CGRect(x: 0.0786, y: 0.3416, width: 0.5377, height: 0.1921)),
        (4327, 25, 89.6, 0.0000, 0.0009, CGRect(x: 0.0936, y: 0.3403, width: 0.5544, height: 0.1841)),
        (4328, 25, 30.1, 0.0000, 0.0003, CGRect(x: 0.2179, y: 0.3862, width: 0.5551, height: 0.1953)),
        (4329, 28, 68.0, 0.0000, 0.0004, CGRect(x: 0.3767, y: 0.4128, width: 0.4202, height: 0.1628)),
        (4330, 28, 72.5, 0.0000, 0.0003, CGRect(x: 0.3765, y: 0.4299, width: 0.4219, height: 0.1702)),
        (4331, 29, 109.7, 0.0000, 0.0005, CGRect(x: 0.3274, y: 0.4614, width: 0.4495, height: 0.1602)),
        (4332, 32, 87.1, 0.0000, 0.0005, CGRect(x: 0.2693, y: 0.3914, width: 0.5564, height: 0.2102)),
        (4333, 32, 66.3, 0.0000, 0.0005, CGRect(x: 0.2898, y: 0.3889, width: 0.5842, height: 0.2083)),
        (4334, 32, 82.6, 0.0000, 0.0007, CGRect(x: 0.2874, y: 0.3889, width: 0.5974, height: 0.2117)),
        (4335, 32, 39.9, 0.0000, 0.0001, CGRect(x: 0.4197, y: 0.3921, width: 0.5569, height: 0.2095)),
        (4336, 35, 63.5, 0.0000, 0.0007, CGRect(x: 0.0406, y: 0.4185, width: 0.6303, height: 0.2085)),
        (4337, 35, 83.8, 0.0000, 0.0010, CGRect(x: 0.1593, y: 0.4231, width: 0.6200, height: 0.1985)),
        (4338, 35, 41.0, 0.0000, 0.0008, CGRect(x: 0.1578, y: 0.3557, width: 0.6083, height: 0.1833)),
        (4339, 35, 82.3, 0.0000, 0.0012, CGRect(x: 0.1523, y: 0.3445, width: 0.6050, height: 0.1990)),
        (4340, 35, 31.5, 0.0000, 0.0005, CGRect(x: 0.1292, y: 0.3408, width: 0.5715, height: 0.1929)),
        (4341, 53, 76.8, 0.0000, 0.0000, CGRect(x: 0.2179, y: 0.3889, width: 0.5516, height: 0.1907)),
        (4342, 53, 136.2, 0.0000, 0.0003, CGRect(x: 0.2216, y: 0.3875, width: 0.5626, height: 0.1926)),
        (4343, 54, 101.1, 0.0000, 0.0003, CGRect(x: 0.2119, y: 0.3777, width: 0.5737, height: 0.1912)),
        (4344, 54, 78.8, 0.0000, 0.0003, CGRect(x: 0.2354, y: 0.3855, width: 0.5776, height: 0.2141)),
        (4345, 54, 108.0, 0.0000, 0.0004, CGRect(x: 0.2063, y: 0.4131, width: 0.6013, height: 0.2095)),
        (4346, 59, 171.1, 0.0000, 0.0000, CGRect(x: 0.2266, y: 0.4214, width: 0.4805, height: 0.1787)),
        (4347, 59, 120.5, 0.0000, 0.0000, CGRect(x: 0.1904, y: 0.4062, width: 0.5010, height: 0.1714)),
        (4348, 59, 120.5, 0.0000, 0.0000, CGRect(x: 0.2034, y: 0.3960, width: 0.5056, height: 0.1685)),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, ($0.1, $0.2, $0.3, $0.4, $0.5)) })
    }()

    /// Real date, measurements and EXIF of the session (Sony A6000, 55-210 mm, as on 04311), and reasons
    /// that match the verdict given above.
    private static func applyRealAnalysis(to photo: Photo, start: Date, best: String, isSingle: Bool) {
        let number = number(of: photo)
        guard let real = realAnalysis[number] else { return }
        photo.captureDate = start + real.seconds
        photo.sharpness = real.sharpness
        photo.highlightClipping = real.highlights
        photo.shadowClipping = real.shadows
        photo.subjectBox = real.subject
        photo.capture = CaptureInfo(
            cameraMake: "SONY", cameraModel: "ILCE-6000", lensModel: "E 55-210mm F4.5-6.3 OSS",
            exposureTime: 1.0 / 160, fNumber: 10, iso: 100, focalLength: 173
        )
        photo.analyzedAt = start + 120
        photo.detailsReadAt = start + 120
        let verdict = photo.cullingVerdict ?? .review
        var reasons: [CullingReason]
        if photo.isBestOfBurst {
            reasons = [CullingReason(kind: .bestOfBurst, verdict: .keep)]
        } else if isSingle {
            // 04317 and 04335: what the probe found.
            reasons = [
                CullingReason(kind: .blurry, verdict: .reject, value: real.sharpness, threshold: 45, onSubject: true),
                CullingReason(kind: .subjectCut, verdict: .reject, value: 0.01, side: .right),
            ]
        } else if verdict == .review {
            reasons = [CullingReason(kind: .burstRunnerUp, verdict: .review, bestPhoto: best)]
        } else {
            reasons = [CullingReason(kind: .burstLoser, verdict: .reject, bestPhoto: best)]
        }
        photo.cullingReasonsData = try? JSONEncoder().encode(reasons)
    }

    /// 4311 for « DSC04311.ARW ».
    private static func number(of photo: Photo) -> Int {
        Int(photo.relativePath.dropFirst(3).prefix(5)) ?? 0
    }

    /// The 14 real thumbnails of the test bundle, by photo number.
    static let fixtureNumbers = [4298, 4300, 4304, 4311, 4315, 4317, 4320, 4327, 4331, 4332, 4335, 4337, 4342, 4346]

    static func fixtureThumbnailURL(_ number: Int) throws -> URL {
        let name = String(format: "DSC%05d", number)
        let bundle = Bundle(for: RenderLibrary.self)
        return try #require(
            bundle.url(forResource: name, withExtension: "jpg")
                ?? bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Thumbnails")
                ?? bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures/Thumbnails"),
            "\(name).jpg missing from the test bundle"
        )
    }

    /// One of the real thumbnails copied into the test bundle (512 px, from the probe of ~/Downloads/photos).
    private static func fixtureThumbnail(_ number: Int) throws -> CGImage {
        let url = try fixtureThumbnailURL(number)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func gallery(_ name: String, path: String, created: Date, in context: ModelContext) -> Gallery {
        let gallery = Gallery(name: name, folderPath: path, folderBookmark: Data(), createdAt: created)
        gallery.indexedAt = created
        context.insert(gallery)
        return gallery
    }

    private static func photos(
        count: Int, prefix: String, firstNumber: Int, start: Date, gallery: Gallery, in context: ModelContext,
        configure: (Int, Photo) -> Void
    ) -> [Photo] {
        (0..<count).map { index in
            let name = "\(prefix)\(firstNumber + index).ARW"
            let photo = Photo(draft: PhotoDraft(
                file: PhotoFile(url: URL(filePath: "/tmp/\(name)"), relativePath: name, fileSize: 24_900_000),
                metadata: PhotoMetadata(captureDate: start + Double(index), pixelWidth: 4000, pixelHeight: 6000),
                importedAt: start
            ))
            context.insert(photo)
            photo.gallery = gallery
            configure(index, photo)
            gallery.photoCount += 1
            return photo
        }
    }

    /// A portrait « photo »: sky, track and a car, in colours that change with `seed`.
    static func drawnPhoto(seed: Int, width: Int = 340, height: Int = 512) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let hue = Double((seed * 47) % 360) / 360
        func color(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
            let rgb = hsbToRGB(h, s, b)
            return CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, 1])!
        }
        let w = Double(width), h = Double(height)
        // Sky (top) and grass, then the grey track: Core Graphics draws from the bottom up.
        context.setFillColor(color(0.58, 0.25, 0.92)); context.fill(CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45))
        context.setFillColor(color(0.3, 0.45, 0.55)); context.fill(CGRect(x: 0, y: h * 0.4, width: w, height: h * 0.15))
        context.setFillColor(color(0, 0, 0.42)); context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.4))
        // The car: body and two wheels, placed a little differently each time.
        let carX = w * (0.12 + Double(seed % 5) * 0.03)
        let body = CGRect(x: carX, y: h * 0.3, width: w * 0.66, height: h * 0.12)
        context.setFillColor(color(hue, 0.55, 0.85))
        context.addPath(CGPath(roundedRect: body, cornerWidth: 18, cornerHeight: 18, transform: nil)); context.fillPath()
        context.setFillColor(color(0, 0, 0.1))
        for x in [body.minX + body.width * 0.2, body.minX + body.width * 0.8] {
            context.fillEllipse(in: CGRect(x: x - 16, y: body.minY - 14, width: 32, height: 32))
        }
        return context.makeImage()!
    }

    private static func hsbToRGB(_ h: Double, _ s: Double, _ b: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        switch i {
        case 0: return (b, t, p)
        case 1: return (q, b, p)
        case 2: return (p, b, t)
        case 3: return (p, q, b)
        case 4: return (t, p, b)
        default: return (b, p, q)
        }
    }
}
