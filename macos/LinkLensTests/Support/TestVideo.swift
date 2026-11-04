import AVFoundation
import CoreVideo
import Foundation
import Testing

/// Writes a real H.264 QuickTime video of `frames` frames at 30 per second, optionally with a
/// recording date and a GPS position (as a camera or an iPhone writes them).
func writeTestVideo(
    in folder: TestFolder,
    _ relativePath: String,
    width: Int = 320,
    height: Int = 240,
    frames: Int,
    withLocation: Bool = false,
    noise: Bool = false
) async throws {
    let file = folder.url.appending(path: relativePath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
    if withLocation {
        writer.metadata = [
            metadataItem(.quickTimeMetadataKeyLocationISO6709, "+48.0000+000.2000/"),
            metadataItem(.quickTimeMetadataKeyCreationDate, "2026-09-20T14:40:57+0200"),
        ]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    try #require(writer.startWriting(), "\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)

    // A few distinct images, shown in turn: filling a buffer per frame would be slow in a test build.
    let images = try (0..<4).map { try makePixelBuffer(width: width, height: height, seed: $0, noise: noise) }
    for index in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(adaptor.append(images[index % images.count], withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
}

private func metadataItem(_ key: AVMetadataKey, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .quickTimeMetadata
    item.key = key.rawValue as NSString
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

/// A plain colour, or random noise (hard to compress, so slow to encode).
private func makePixelBuffer(width: Int, height: Int, seed: Int, noise: Bool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(pixels))
    let length = CVPixelBufferGetBytesPerRow(pixels) * height
    if noise {
        arc4random_buf(base, length)
    } else {
        memset(base, Int32(40 + seed * 50), length)
    }
    return pixels
}
