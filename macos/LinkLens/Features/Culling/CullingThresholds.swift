import Foundation

/// Every culling threshold, in one place. First calibrated with the LinkLensProbe prototype on one minute
/// of car panning (52 photos), then recalibrated on a varied gallery of 4,120 photos (car shows, details,
/// interiors, people, night, sunsets). Not shown to the user: no technical setting by default.
struct CullingThresholds: Sendable, Equatable {
    // MARK: Blur (`Sharpness`: edge crispness of the subject, about 100 when sharp; image scaled to `analysisLongSide`)
    /// Long side, in pixels, of the grayscale image used for blur and exposure.
    var analysisLongSide = 1024
    /// Below this score a photo is clearly blurry: "Rejeter" if it is also among the least sharp of
    /// its gallery (`blurRejectGalleryShare`), otherwise "À revoir".
    var blurReject = 42.0
    /// The same when no subject was found and the whole image is measured: lower, because the background
    /// of a panning shot is blurred on purpose around a sharp car.
    var blurRejectWithoutSubject = 35.0
    /// A blurry subject with something this sharp around it (`SharpnessMeasurement.surroundingSharpness`)
    /// is only "À revoir": the focus may be on purpose elsewhere (a spectator in front of a sharp car).
    var blurSharpAround = 55.0
    /// Below this score a photo is slightly blurry: "À revoir" if it is also among the least sharp of
    /// its gallery (`blurReviewGalleryShare`).
    var blurReview = 50.0
    /// Share of the gallery (0…1): a photo must be among the least sharp ones to be called blurry, so a
    /// gallery shot in hard conditions (night, long lens) is judged against itself.
    var blurRejectGalleryShare = 0.10
    var blurReviewGalleryShare = 0.25
    /// Smaller galleries are judged on the scores alone (a share of a few photos means nothing).
    var blurMinGalleryForShare = 20

    // MARK: Framing (main subject only; never "Rejeter")
    /// A main subject larger than this share of the image is a detail or a close-up that fills the
    /// frame on purpose: no framing check.
    var framingMaxSubjectArea = 0.30
    /// A subject wider than this share of the image touching both sides is expected.
    var framingMaxSubjectWidth = 0.8
    /// Vision's boxes are coarse: below this confidence (0…1) the box often covers a whole scene
    /// (fence, grandstand) rather than one subject, so it is not checked.
    var framingMinConfidence = 0.55
    /// Another salient object at least this share of the main one makes a scene with several subjects
    /// (car show, people in front): no framing check.
    var framingOtherSubjectShare = 0.25
    /// Below this margin (share of the image width) the subject touches the left or right border: "À revoir".
    var subjectCutMargin = 0.01

    // MARK: Exposure (share of pixels, 0…1)
    var highlightReview = 0.05
    var highlightReject = 0.20
    var shadowReview = 0.30
    /// Almost the whole photo is black (lens cap, flash that did not fire): "Rejeter".
    var shadowReject = 0.97

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
    /// Max feature-print distance between a photo and the first one of its burst: a burst that drifts
    /// (same car, but in front of the trees, then of the grandstand) is split.
    var burstMaxDistanceFromFirst = 0.35
    /// Max time between the first and the last photo of a burst, in seconds.
    var burstMaxDurationSeconds = 2.0
    /// Max photos in a burst (the A6000 shoots 11 per second).
    var burstMaxCount = 20
    /// A burst photo scoring at least this ratio of the best one is "À revoir", below it "Rejeter".
    var burstRunnerUpRatio = 0.90
    var burstWeightSharpness = 0.45
    var burstWeightAesthetics = 0.25
    var burstWeightFaceQuality = 0.20
    var burstWeightEyesOpen = 0.10
}
