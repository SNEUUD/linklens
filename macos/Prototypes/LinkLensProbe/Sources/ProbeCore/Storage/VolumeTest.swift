import Foundation
import SwiftData

public struct VolumeTestResult: Sendable {
    public var photoCount: Int
    public var galleryCount: Int
    public var batchSize: Int
    public var insertSeconds: Double
    public var firstBatchSeconds: Double
    public var lastBatchSeconds: Double
    public var coldQuerySeconds: Double
    public var warmQueryMedianSeconds: Double
    public var queryResultCount: Int
    public var memoryBeforeMB: Double
    public var memoryAfterMB: Double
    public var memoryPeakMB: Double
    public var storeSizeMB: Double

    // Alert levels proposed in the plan.
    public static let maxInsertSeconds = 10.0
    public static let maxQuerySeconds = 0.050
    public static let maxPeakMemoryMB = 300.0

    public var problems: [String] {
        var problems: [String] = []
        if insertSeconds > Self.maxInsertSeconds {
            problems.append("insertion trop lente (\(format(insertSeconds, 1)) s > \(format(Self.maxInsertSeconds, 0)) s)")
        }
        if warmQueryMedianSeconds > Self.maxQuerySeconds {
            problems.append("requête trop lente (\(format(warmQueryMedianSeconds * 1000, 1)) ms > \(format(Self.maxQuerySeconds * 1000, 0)) ms)")
        }
        if memoryPeakMB > Self.maxPeakMemoryMB {
            problems.append("mémoire trop élevée (\(format(memoryPeakMB, 0)) Mo > \(format(Self.maxPeakMemoryMB, 0)) Mo)")
        }
        if lastBatchSeconds > firstBatchSeconds * 3, lastBatchSeconds > 0.2 {
            problems.append("les lots ralentissent avec le volume (\(format(firstBatchSeconds * 1000, 0)) ms → \(format(lastBatchSeconds * 1000, 0)) ms)")
        }
        return problems
    }

    public var summary: String {
        var lines = [
            "",
            "Test de volume SwiftData",
            "  Données          : \(photoCount) photos dans \(galleryCount) galeries, lots de \(batchSize)",
            "  Insertion        : \(format(insertSeconds, 2)) s (\(format(Double(photoCount) / max(insertSeconds, 0.000_001), 0)) photos/s)",
            "  Premier / dernier lot : \(format(firstBatchSeconds * 1000, 0)) ms / \(format(lastBatchSeconds * 1000, 0)) ms",
            "  Requête « 50 meilleures non rejetées d'une galerie » :",
            "    à froid        : \(format(coldQuerySeconds * 1000, 1)) ms",
            "    à chaud        : \(format(warmQueryMedianSeconds * 1000, 1)) ms (médiane de 20)",
            "    résultats      : \(queryResultCount)",
            "  Mémoire          : \(format(memoryBeforeMB, 0)) Mo avant → \(format(memoryAfterMB, 0)) Mo après (pic \(format(memoryPeakMB, 0)) Mo)",
            "  Taille de la base: \(format(storeSizeMB, 1)) Mo",
            "",
        ]
        if problems.isEmpty {
            lines.append("✅ Performances suffisantes : SwiftData convient pour 10 000 photos.")
        } else {
            lines.append("❌ PROBLÈME DE PERFORMANCE : " + problems.joined(separator: " ; "))
            lines.append("   → Envisager GRDB, la solution de repli prévue dans le cahier des charges.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Inserts fake but realistic photos into a fresh SwiftData store, then measures it.
public enum VolumeTest {
    public static func run(count: Int, galleryCount: Int, batchSize: Int, storeURL: URL) async throws -> VolumeTestResult {
        try removeStore(at: storeURL)
        let memoryBefore = Memory.footprint()

        let schema = Schema([Gallery.self, Photo.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
        let store = PhotoStore(modelContainer: container)

        var galleryIds: [UUID] = []
        for number in 1...max(1, galleryCount) {
            galleryIds.append(try await store.createGallery(name: "Séance \(number)"))
        }

        // Insertion, batch by batch, inside the ModelActor.
        var generator = SeededGenerator(seed: 42)
        let clock = ContinuousClock()
        let insertStart = clock.now
        var batchDurations: [Double] = []
        let perGallery = count / galleryIds.count
        let progress = ProgressReporter(total: count, label: "Insertion")
        for (galleryIndex, galleryId) in galleryIds.enumerated() {
            let galleryCountForThis = galleryIndex == galleryIds.count - 1 ? count - perGallery * galleryIndex : perGallery
            let drafts = FakePhotos.make(count: galleryCountForThis, galleryIndex: galleryIndex, using: &generator)
            for batchStart in stride(from: 0, to: drafts.count, by: batchSize) {
                let batch = Array(drafts[batchStart..<min(batchStart + batchSize, drafts.count)])
                let start = clock.now
                try await store.insert(batch, galleryId: galleryId)
                batchDurations.append(start.duration(to: clock.now).seconds)
                await progress.advance(by: batch.count)
            }
        }
        let insertSeconds = insertStart.duration(to: clock.now).seconds
        let memoryAfter = Memory.footprint()
        let storedCount = try await store.photoCount()
        guard storedCount == count else {
            throw ProbeError.storeFailure("\(storedCount) photos en base au lieu de \(count)")
        }

        // Query on a brand-new container and context ("cold"), then repeated ("warm").
        let queryContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
        let queryStore = PhotoStore(modelContainer: queryContainer)
        let target = galleryIds[galleryIds.count / 2]
        let coldStart = clock.now
        let results = try await queryStore.bestPhotos(galleryId: target, limit: 50)
        let coldSeconds = coldStart.duration(to: clock.now).seconds
        var warm: [Double] = []
        for repetition in 0..<20 {
            let galleryId = galleryIds[repetition % galleryIds.count]
            let start = clock.now
            _ = try await queryStore.bestPhotos(galleryId: galleryId, limit: 50)
            warm.append(start.duration(to: clock.now).seconds)
        }
        warm.sort()

        let peak = Memory.footprint().peak
        return VolumeTestResult(
            photoCount: count,
            galleryCount: galleryIds.count,
            batchSize: batchSize,
            insertSeconds: insertSeconds,
            firstBatchSeconds: batchDurations.first ?? 0,
            lastBatchSeconds: batchDurations.last ?? 0,
            coldQuerySeconds: coldSeconds,
            warmQueryMedianSeconds: warm[warm.count / 2],
            queryResultCount: results.count,
            memoryBeforeMB: Memory.megabytes(memoryBefore.current),
            memoryAfterMB: Memory.megabytes(memoryAfter.current),
            memoryPeakMB: Memory.megabytes(max(peak, memoryAfter.peak)),
            storeSizeMB: Memory.megabytes(storeSize(at: storeURL))
        )
    }

    /// SQLite keeps 3 files: the store, its write-ahead log (-wal) and shared memory (-shm).
    private static func storeFiles(at url: URL) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
    }

    private static func removeStore(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in storeFiles(at: url) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func storeSize(at url: URL) -> UInt64 {
        storeFiles(at: url).reduce(0) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
            return total + size
        }
    }
}

/// Generates plausible photos: dates every ~1.5 s, bursts of ~5, scores, verdicts 55/30/15 %.
enum FakePhotos {
    static func make(count: Int, galleryIndex: Int, using generator: inout SeededGenerator) -> [PhotoDraft] {
        let sessionStart = Date(timeIntervalSince1970: 1_780_000_000 + Double(galleryIndex) * 86_400)
        var drafts: [PhotoDraft] = []
        drafts.reserveCapacity(count)
        var burstId: UUID?
        var burstRemaining = 0
        for index in 0..<count {
            if burstRemaining == 0 {
                burstRemaining = Int.random(in: 1...8, using: &generator)
                burstId = burstRemaining > 1 ? UUID() : nil
            }
            let isBest = burstId != nil && burstRemaining == 1
            burstRemaining -= 1

            let roll = Double.random(in: 0..<1, using: &generator)
            let verdict: Verdict = roll < 0.55 ? .keep : roll < 0.85 ? .review : .reject
            let reason = switch verdict {
            case .keep: ""
            case .review: "Légèrement floue (netteté 72 < 100)"
            case .reject: "Moins bonne de la rafale (meilleure : DSC01234.ARW)"
            }
            var printWords = [UInt64](repeating: 0, count: 384) // 768 Float = 3 072 bytes
            for word in printWords.indices { printWords[word] = generator.next() }

            drafts.append(PhotoDraft(
                id: UUID(),
                relativePath: String(format: "Séance %02d/DSC%05d.ARW", galleryIndex + 1, index),
                captureDate: sessionStart.addingTimeInterval(Double(index) * 1.5),
                importedAt: Date(),
                pixelWidth: 6000,
                pixelHeight: 4000,
                fileSize: Int64.random(in: 22_000_000...27_000_000, using: &generator),
                aestheticScore: Double.random(in: -1...1, using: &generator),
                sharpness: Double.random(in: 5...900, using: &generator),
                faceCount: Int.random(in: 0...4, using: &generator),
                eyesClosed: Double.random(in: 0..<1, using: &generator) < 0.08,
                verdict: verdict,
                reason: reason,
                burstId: burstId,
                isBestOfBurst: isBest,
                sha256: (0..<4).map { _ in String(format: "%016llx", generator.next()) }.joined(),
                featurePrint: printWords.withUnsafeBytes { Data($0) }
            ))
        }
        return drafts
    }
}

/// Reproducible random numbers (SplitMix64): every run inserts exactly the same data.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func format(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}
