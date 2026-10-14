import Foundation

/// Every culling threshold, in one place.
/// Override any subset without recompiling: `analyze --thresholds my-thresholds.json`
/// (`analyze --print-thresholds` prints the current values as JSON).
public struct Thresholds: Codable, Sendable, Equatable {
    // MARK: Blur (Laplacian variance ÷ contrast × 1000, on the subject; image scaled to `analysisLongSide`)
    /// Long side, in pixels, of the grayscale image used for blur and exposure.
    public var analysisLongSide = 1024
    /// Calibrated on the first real session (car panning shots): values ranged from 35 to 203.
    public var blurReview = 65.0
    public var blurReject = 45.0

    // MARK: Framing (distance between the subject and the image border, share of the image size)
    /// Below this margin the subject is considered cut by the border ("Rejeter").
    public var subjectCutMargin = 0.03
    /// Below this margin the subject is considered too close to the border ("À revoir").
    public var subjectTightMargin = 0.05
    /// Subjects larger than this (share of width or height) fill the frame: no framing check on that axis.
    public var framingMaxSubjectSize = 0.8

    // MARK: Exposure (share of pixels, 0…1)
    public var highlightReview = 0.05
    public var highlightReject = 0.20
    public var shadowReview = 0.30

    // MARK: Faces and eyes
    /// Eye openness (height / width) below which an eye is considered closed.
    public var eyeClosedOpenness = 0.15
    /// Faces smaller than this (height in pixels, in the analysed image) get no eye verdict.
    public var minFaceHeightForEyes = 80.0

    // MARK: Aesthetics (Vision overallScore, −1…1)
    public var aestheticsReview = -0.3

    // MARK: Bursts
    /// Max gap between two consecutive photos of a burst, in seconds.
    public var burstMaxGapSeconds = 2.0
    /// Max feature-print distance between two consecutive photos of a burst.
    /// Calibrated on the first real session: ≤ 0.24 inside bursts, ≥ 0.34 between them.
    public var burstMaxDistance = 0.30
    /// A burst photo scoring at least this ratio of the best one is "À revoir", below it "Rejeter".
    public var burstRunnerUpRatio = 0.90
    public var burstWeightSharpness = 0.45
    public var burstWeightAesthetics = 0.25
    public var burstWeightFaceQuality = 0.20
    public var burstWeightEyesOpen = 0.10

    public init() {}

    /// Loads a JSON file containing all or only some of the keys; missing keys keep their default value.
    public static func load(from url: URL) throws -> Thresholds {
        do {
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Thresholds())) as? [String: Any] ?? [:]
            guard let overrides = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw ProbeError.invalidThresholds("le fichier doit contenir un objet JSON")
            }
            let unknown = Set(overrides.keys).subtracting(defaults.keys)
            guard unknown.isEmpty else {
                throw ProbeError.invalidThresholds("clés inconnues : \(unknown.sorted().joined(separator: ", "))")
            }
            let merged = defaults.merging(overrides) { _, new in new }
            return try JSONDecoder().decode(Thresholds.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch let error as ProbeError {
            throw error
        } catch {
            throw ProbeError.invalidThresholds(error.localizedDescription)
        }
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
