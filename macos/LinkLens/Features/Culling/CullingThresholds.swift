import Foundation

/// Every culling threshold, in one place. Values calibrated and validated with the LinkLensProbe
/// prototype on a real session (car panning shots). Not shown to the user: no technical setting by default.
struct CullingThresholds: Sendable, Equatable {
    // MARK: Blur (Laplacian variance ÷ contrast × 1000, on the subject; image scaled to `analysisLongSide`)
    /// Long side, in pixels, of the grayscale image used for blur and exposure.
    var analysisLongSide = 1024
    /// Calibrated on the first real session: values ranged from 35 to 203.
    var blurReview = 65.0
    var blurReject = 45.0

    // MARK: Framing (distance between the subject and the image border, share of the image size)
    /// Below this margin the subject is considered cut by the border ("Rejeter").
    var subjectCutMargin = 0.03
    /// Below this margin the subject is considered too close to the border ("À revoir").
    var subjectTightMargin = 0.05
    /// Subjects larger than this (share of width or height) fill the frame: no framing check on that axis.
    var framingMaxSubjectSize = 0.8

    // MARK: Exposure (share of pixels, 0…1)
    var highlightReview = 0.05
    var highlightReject = 0.20
    var shadowReview = 0.30

    // MARK: Faces and eyes (not validated on portraits yet: "À revoir" at most)
    /// Eye openness (height / width) below which an eye is considered closed.
    var eyeClosedOpenness = 0.15
    /// Faces smaller than this (height in pixels, in the analysed image) get no eye verdict.
    var minFaceHeightForEyes = 80.0

    // MARK: Aesthetics (Vision overallScore, −1…1)
    var aestheticsReview = -0.3

    // MARK: Bursts
    /// Max gap between two consecutive photos of a burst, in seconds.
    var burstMaxGapSeconds = 2.0
    /// Max feature-print distance between two consecutive photos of a burst.
    /// Calibrated on the first real session: ≤ 0.24 inside bursts, ≥ 0.34 between them.
    var burstMaxDistance = 0.30
    /// A burst photo scoring at least this ratio of the best one is "À revoir", below it "Rejeter".
    var burstRunnerUpRatio = 0.90
    var burstWeightSharpness = 0.45
    var burstWeightAesthetics = 0.25
    var burstWeightFaceQuality = 0.20
    var burstWeightEyesOpen = 0.10
}
