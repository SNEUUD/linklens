import Foundation

// MARK: - Verdict and reasons

public enum Verdict: String, Codable, Sendable, Comparable, CaseIterable {
    case keep, review, reject

    /// Text shown to the user.
    public var label: String {
        switch self {
        case .keep: "Garder"
        case .review: "À revoir"
        case .reject: "Rejeter"
        }
    }

    private var severity: Int {
        switch self {
        case .keep: 0
        case .review: 1
        case .reject: 2
        }
    }

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.severity < rhs.severity }
}

public enum ReasonCode: String, Codable, Sendable {
    case blurry, slightlyBlurry
    case overexposed, slightlyOverexposed, underexposed
    case eyesClosed
    case lowAesthetics, utility
    case exactDuplicate
    case burstRunnerUp, burstLoser
}

/// Why a photo got its verdict. `message` is the French text shown to the user.
public struct Reason: Codable, Sendable, Equatable {
    public var code: ReasonCode
    public var verdict: Verdict
    public var message: String
}

// MARK: - Report

public struct PhotoResult: Codable, Sendable {
    public var fileName: String
    public var relativePath: String
    public var fileSize: Int64
    public var sha256: String
    public var captureDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var previewSource: PreviewSource
    public var aesthetics: Double?
    public var isUtility: Bool?
    public var faces: [FaceResult]
    public var sharpness: Double
    public var globalSharpness: Double
    public var highlightClipping: Double
    public var shadowClipping: Double
    public var burstId: Int?
    public var isBestOfBurst: Bool
    public var burstScore: Double?
    public var verdict: Verdict
    /// Sorted from most to least severe; the first one is the main reason.
    public var reasons: [Reason]
    public var thumbnail: String
}

public struct Burst: Codable, Sendable {
    public var id: Int
    public var photos: [String]
    public var best: String
}

/// Distance between two photos that follow each other in time (to calibrate the burst threshold).
public struct NeighborDistance: Codable, Sendable {
    public var from: String
    public var to: String
    public var secondsApart: Double?
    public var distance: Double?
    public var sameBurst: Bool
}

public struct AnalysisFailure: Codable, Sendable {
    public var relativePath: String
    public var message: String
}

public struct RunStats: Codable, Sendable {
    public var photoCount: Int
    public var failedCount: Int
    public var totalSeconds: Double
    public var photosPerSecond: Double
    public var concurrency: Int
    public var verdictCounts: [String: Int]
    /// Sum over all photos (tasks run in parallel, so this exceeds `totalSeconds`).
    public var stageSeconds: StageTimings
    public var embeddedPreviews: Int
    public var decodedImages: Int
}

public struct AnalysisReport: Codable, Sendable {
    public var generatedAt: Date
    public var sourceFolder: String
    public var thresholds: Thresholds
    public var stats: RunStats
    public var bursts: [Burst]
    public var neighborDistances: [NeighborDistance]
    public var failures: [AnalysisFailure]
    public var photos: [PhotoResult]
}

extension AnalysisReport {
    public static func load(from url: URL) throws -> AnalysisReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnalysisReport.self, from: Data(contentsOf: url))
    }
}
