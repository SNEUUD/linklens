import CoreGraphics
import Foundation
import Vision

struct FaceResult: Sendable, Equatable {
    /// Normalized (0…1), origin at the top-left (like CSS).
    var boundingBox: CGRect
    /// Vision capture quality (0…1). Only meaningful to compare shots of the same person.
    var captureQuality: Double?
    /// Mean openness of both eyes (height / width). Nil if the face is too small to judge.
    var eyeOpenness: Double?
    /// Nil = unknown (face too small or landmarks missing).
    var eyesClosed: Bool?
}

/// One object that stands out in the photo (Vision "objectness" saliency).
struct SalientObject: Sendable, Equatable, Codable {
    /// Normalized (0…1), origin at the top-left.
    var box: CGRect
    /// Vision confidence (0…1).
    var confidence: Double

    var area: Double { Double(box.width * box.height) }
}

struct VisionMeasurement: Sendable {
    var aesthetics: Double?
    var isUtility: Bool?
    var faces: [FaceResult]
    var featurePrint: FeaturePrintObservation?
    /// Every salient object Vision found, largest first.
    var salientObjects: [SalientObject] = []

    /// Main subject: the largest salient object, normalized with a top-left origin. Nil if none found.
    var subjectBox: CGRect? { salientObjects.first?.box }
}

/// Runs the Vision requests on an upright image, using the Swift Vision API (macOS 15+).
enum VisionAnalyzer {
    static func analyze(_ image: CGImage, thresholds: CullingThresholds) async throws -> VisionMeasurement {
        let handler = ImageRequestHandler(image)
        let imageSize = CGSize(width: image.width, height: image.height)

        // Four independent requests on the same image, performed together.
        let (scores, qualityFaces, featurePrint, saliency) = try await handler.perform(
            CalculateImageAestheticsScoresRequest(),
            DetectFaceCaptureQualityRequest(),
            GenerateImageFeaturePrintRequest(),
            GenerateObjectnessBasedSaliencyImageRequest()
        )

        // Landmarks (eye contours) for the faces found above.
        var landmarkFaces: [FaceObservation] = []
        if !qualityFaces.isEmpty {
            var landmarksRequest = DetectFaceLandmarksRequest()
            landmarksRequest.inputFaceObservations = qualityFaces
            landmarkFaces = try await handler.perform(landmarksRequest)
        }

        let faces = qualityFaces.map { face in
            let landmarks = closest(to: face.boundingBox.cgRect, in: landmarkFaces)?.landmarks
            return faceResult(face: face, landmarks: landmarks, imageSize: imageSize, thresholds: thresholds)
        }
        return VisionMeasurement(
            aesthetics: Double(scores.overallScore),
            isUtility: scores.isUtility,
            faces: faces,
            featurePrint: featurePrint,
            salientObjects: salientObjects(from: saliency)
        )
    }

    /// Only the subject box, for photos analysed before it was stored (`DetailsBackfiller`): the same
    /// saliency request as `analyze`, without the three others.
    static func subjectBox(of image: CGImage) async throws -> CGRect? {
        let saliency = try await ImageRequestHandler(image).perform(GenerateObjectnessBasedSaliencyImageRequest())
        return salientObjects(from: saliency).first?.box
    }

    /// "Objectness" saliency finds the objects that stand out (a car, a person, a wheel…).
    /// They are kept apart, largest first: merging them made one huge "subject" out of a car show
    /// and called it cut by the border.
    static func salientObjects(from saliency: SaliencyImageObservation) -> [SalientObject] {
        saliency.salientObjects
            .map { SalientObject(box: topLeft($0.boundingBox.cgRect), confidence: Double($0.confidence)) }
            .filter { $0.box.width > 0 && $0.box.height > 0 }
            .sorted { $0.area > $1.area }
    }

    /// Vision uses a bottom-left origin; the rest of the app uses a top-left origin (like CSS).
    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    private static func faceResult(
        face: FaceObservation,
        landmarks: FaceObservation.Landmarks2D?,
        imageSize: CGSize,
        thresholds: CullingThresholds
    ) -> FaceResult {
        let box = face.boundingBox.cgRect
        let faceHeightPixels = Double(box.height * imageSize.height)

        var openness: Double?
        if let landmarks, faceHeightPixels >= thresholds.minFaceHeightForEyes {
            let left = EyeState.openness(of: landmarks.leftEye.pointsInImageCoordinates(imageSize))
            let right = EyeState.openness(of: landmarks.rightEye.pointsInImageCoordinates(imageSize))
            let values = [left, right].compactMap { $0 }
            if !values.isEmpty { openness = values.reduce(0, +) / Double(values.count) }
        }
        return FaceResult(
            boundingBox: topLeft(box),
            captureQuality: face.captureQuality.map { Double($0.score) },
            eyeOpenness: openness,
            eyesClosed: openness.map { $0 < thresholds.eyeClosedOpenness }
        )
    }

    /// Matches a face from one request with the same face in another request (closest center).
    private static func closest(to box: CGRect, in faces: [FaceObservation]) -> FaceObservation? {
        faces.min { a, b in
            centerDistance(a.boundingBox.cgRect, box) < centerDistance(b.boundingBox.cgRect, box)
        }
    }

    private static func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}
