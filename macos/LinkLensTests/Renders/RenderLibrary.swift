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

    init() throws {
        container = try ModelContainer(
            for: Gallery.self, Photo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = LibraryStore(modelContainer: container)
        availabilityMonitor = GalleryAvailabilityMonitor(store: store)
        cache = ThumbnailCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "LinkLensRenderThumbnails-\(UUID().uuidString)", directoryHint: .isDirectory))
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_789_915_257) // 20 Sept. 2026, 14:40:57

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
    }

    deinit {
        try? FileManager.default.removeItem(at: cache.directory)
    }

    var galleries: [Gallery] { [session, wedding, forest] }

    /// The real main window, with the controllers it needs, showing `selectedGallery`.
    func mainWindow(selecting selectedGallery: Gallery?) -> some View {
        let importController = ImportController(store: store)
        importController.selectedGalleryId = selectedGallery?.id
        return withEnvironment(ContentView(), importController: importController)
            .frame(minWidth: 1080, minHeight: 560)
    }

    /// Gives `view` every object the app provides at its root, with this catalogue and cache.
    func withEnvironment(_ view: some View, importController: ImportController? = nil) -> some View {
        view
            .environment(importController ?? ImportController(store: store))
            .environment(CullingController(store: store))
            .environment(exportController)
            .environment(CardImportController(importer: CardImporter(store: store)))
            .environment(CardMonitor())
            .environment(DuplicatesController(store: store))
            .environment(availabilityMonitor)
            .environment(\.thumbnailCache, cache)
            .modelContainer(container)
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

    /// 4311 for « DSC04311.ARW ».
    private static func number(of photo: Photo) -> Int {
        Int(photo.relativePath.dropFirst(3).prefix(5)) ?? 0
    }

    /// One of the real thumbnails copied into the test bundle (512 px, from the probe of ~/Downloads/photos).
    private static func fixtureThumbnail(_ number: Int) throws -> CGImage {
        let name = String(format: "DSC%05d", number)
        let bundle = Bundle(for: RenderLibrary.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "jpg")
                ?? bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Thumbnails")
                ?? bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures/Thumbnails"),
            "\(name).jpg missing from the test bundle"
        )
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
